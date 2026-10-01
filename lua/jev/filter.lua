--- Relevance filtering of tool output.
---
--- A tool result is re-sent to the model on every later turn, so the bytes it
--- adds are paid many times. This scores each block of a large result against
--- what the agent is doing and drops the low scorers before the result enters
--- history.
---
--- Builders who A/B tested this shape found it can lose end to end: an elided
--- block the agent needed costs a re-run, which costs more than the bytes
--- saved. Putting the agent's intent in the state was what cut those wrong
--- elisions, so `state` carries the goal and the intent, and the floor is low.

local client = require("jev.client")
local config = require("jev.config")
local context = require("jev.context")

local MIN_FILTER_BYTES = 4 * 1024
local MIN_CHUNKS = 4
local MAX_CHUNK_LINES = 60
local WINDOW_BYTES = 40 * 1024
local NEUTRAL_SCORE = 0.5
local MIN_GAIN = 0.9
local CALL_BYTES = 600
local RECORD_AVG_LINES = 1.5
local PARAGRAPH_MAX_LINES = 40
local COALESCE_MAX_LINES = 10

local QUESTION = "Should the agent keep `block`, one part of the output of `call`, in its context?"
local CRITERIA = {
  ["true"] = "It reports an error, failure, assertion, stack trace, diagnostic, or final summary, "
    .. "or holds a fact that `intent` or `goal` is looking for",
  ["false"] = "Routine progress output, compile or download chatter, repeated success lines, "
    .. "banners, timings, boilerplate, or detail unrelated to `goal` and `intent`",
}

local M = {}

--- Batch and code_execution in flight per session. Their nested calls look
--- alike to a layer, but only batch hands the text to the model as is.
local inflight = {}

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function indent_of(line)
  return #line:match("^[ \t]*")
end

--- A record is a head line plus the lines indented deeper than it. Comparing
--- against the head's own indent rather than against zero is what makes this
--- work on cargo, which indents `   Compiling` and `    Finished` by three and
--- four spaces. Treating any leading space as a continuation merges a whole
--- build log into one record.
---
--- Groups rustc diagnostics, tracebacks, pytest sections, and the
--- `path:` / `  12: hit` shape the grep tool renders.
local function records(lines)
  local out, cur, head = {}, nil, 0
  for _, line in ipairs(lines) do
    if cur and (line == "" or indent_of(line) > head) then
      cur[#cur + 1] = line
    else
      if cur then
        out[#out + 1] = cur
      end
      cur, head = { line }, indent_of(line)
    end
  end
  if cur then
    out[#out + 1] = cur
  end
  return out
end

--- Runs of one-line records (`test ... ok`, a list of paths) carry no structure
--- worth scoring one at a time. Grouping them keeps the question count sane and
--- stops the result from being shredded by single-line elision markers.
local function coalesce(blocks, size)
  local out, run = {}, nil
  for _, block in ipairs(blocks) do
    if #block == 1 and run and #run < size then
      run[#run + 1] = block[1]
    elseif #block == 1 then
      if run then
        out[#out + 1] = run
      end
      run = { block[1] }
    else
      if run then
        out[#out + 1] = run
        run = nil
      end
      out[#out + 1] = block
    end
  end
  if run then
    out[#out + 1] = run
  end
  return out
end

local function paragraphs(lines)
  local out, cur = {}, {}
  for _, line in ipairs(lines) do
    if line == "" and #cur > 0 then
      out[#out + 1] = cur
      cur = {}
    elseif line ~= "" then
      cur[#cur + 1] = line
    end
  end
  if #cur > 0 then
    out[#out + 1] = cur
  end
  return out
end

local function windows(lines, size)
  local out, cur = {}, {}
  for _, line in ipairs(lines) do
    cur[#cur + 1] = line
    if #cur >= size then
      out[#out + 1] = cur
      cur = {}
    end
  end
  if #cur > 0 then
    out[#out + 1] = cur
  end
  return out
end

local function cap(blocks, size)
  local out = {}
  for _, block in ipairs(blocks) do
    if #block <= size then
      out[#out + 1] = block
    else
      for _, piece in ipairs(windows(block, size)) do
        out[#out + 1] = piece
      end
    end
  end
  return out
end

--- Never split below a record: half a stack trace is worse than none.
local function chunk_text(text)
  local lines = split_lines(text)
  local blocks = records(lines)
  if #blocks < MIN_CHUNKS or (#lines / #blocks) < RECORD_AVG_LINES then
    local flat = paragraphs(lines)
    if #flat >= MIN_CHUNKS then
      blocks = flat
    elseif #blocks < MIN_CHUNKS then
      blocks = windows(lines, PARAGRAPH_MAX_LINES)
    end
  end
  blocks = cap(coalesce(blocks, COALESCE_MAX_LINES), MAX_CHUNK_LINES)

  local chunks = {}
  for i, block in ipairs(blocks) do
    chunks[i] = { text = table.concat(block, "\n"), nlines = #block }
  end
  return chunks
end

--- Each block rides in its own question, next to the question text, rather
--- than in a numbered list in `state`: pointing Jev at "block 7" of a big
--- state is indirection, which jev-1.13 reads poorly.
local function score_window(state, chunks, from, to)
  local questions = {}
  for i = from, to do
    questions["c" .. i] = {
      type = "noul",
      instructions = { question = QUESTION, block = chunks[i].text },
      criteria = CRITERIA,
    }
  end
  local answers, err = client.ask(state, questions)
  if not answers then
    return nil, err
  end
  local scores = {}
  for i = from, to do
    scores[i] = client.noul(answers, "c" .. i) or NEUTRAL_SCORE
  end
  return scores
end

local function score(state, chunks)
  local jobs, bytes, from = {}, 0, 1
  for i, chunk in ipairs(chunks) do
    bytes = bytes + #chunk.text
    if bytes >= WINDOW_BYTES or i == #chunks then
      local a, b = from, i
      jobs[#jobs + 1] = function()
        return score_window(state, chunks, a, b)
      end
      bytes, from = 0, i + 1
    end
  end

  local scores, failed = {}, 0
  for _, result in ipairs(maki.async.gather(jobs)) do
    if result.ok and result.value then
      for i, value in pairs(result.value) do
        scores[i] = value
      end
    else
      failed = failed + 1
    end
  end
  if failed == #jobs then
    return nil
  end
  return scores
end

--- The score floor is the only gate. Filling up to a byte target instead
--- shreds uniformly structured output like `git log`, where every block scores
--- alike and the target ends up ranking 0.50 against 0.52. If every block reads
--- as relevant, keeping them all is the right answer: `MIN_GAIN` abstains when
--- little was dropped.
---
--- The first and last block are kept unconditionally: in command output they
--- carry the invocation and the exit status, and both are cheap.
local function select_chunks(chunks, scores, floor)
  local keep = { [1] = true, [#chunks] = true }
  for i = 1, #chunks do
    if (scores[i] or NEUTRAL_SCORE) >= floor then
      keep[i] = true
    end
  end
  return keep
end

--- An elision marker is not decoration. Without it the model reads a filtered
--- result as an exhaustive one and stops looking. The line range makes the drop
--- recoverable: the caller can re-run narrowed to exactly those lines.
local function reassemble(chunks, keep)
  local parts, line_no, from, dropped = {}, 0, nil, 0
  local function flush()
    if from then
      parts[#parts + 1] = string.format("[lines %d-%d elided]", from, from + dropped - 1)
      from, dropped = nil, 0
    end
  end

  for i, chunk in ipairs(chunks) do
    if keep[i] then
      flush()
      parts[#parts + 1] = chunk.text
    else
      from = from or line_no + 1
      dropped = dropped + chunk.nlines
    end
    line_no = line_no + chunk.nlines
  end
  flush()
  return table.concat(parts, "\n")
end

local function filter(out, ctx)
  local text = out.text
  if #text < MIN_FILTER_BYTES then
    return nil
  end
  local chunks = chunk_text(text)
  if #chunks < MIN_CHUNKS then
    return nil
  end

  local stats = config.stats
  stats.filter_seen = stats.filter_seen + 1
  local state = {
    goal = context.goal(ctx.session_id) or "unknown",
    intent = context.intent(ctx.session_id) or "unknown",
    call = context.describe_call(ctx.tool, ctx.input, CALL_BYTES),
  }
  local scores = score(state, chunks)
  if not scores then
    return nil
  end

  local floor = out.is_error and config.opts.filter_min_score_error or config.opts.filter_min_score
  local keep = select_chunks(chunks, scores, floor)
  local filtered = reassemble(chunks, keep)
  if #filtered >= math.floor(#text * MIN_GAIN) then
    return nil
  end

  local kept = 0
  for _ in pairs(keep) do
    kept = kept + 1
  end
  stats.filtered = stats.filtered + 1
  stats.filter_saved = stats.filter_saved + (#text - #filtered)
  maki.log.info(string.format(
    "jev filter: %s %d -> %d bytes, %d/%d blocks kept, floor %.2f",
    ctx.tool,
    #text,
    #filtered,
    kept,
    #chunks,
    floor
  ))
  return filtered
end

-- Lives in the cached system prefix, written once and read on every turn, so it
-- stays short. The absence-of-evidence line is the load-bearing one: a filtered
-- search that shows no match is not proof that no match exists.
local HINT = table.concat({
  "- `[lines N-M elided]` in tool output is maki's relevance filter, not the tool.",
  "  Dropped text scored irrelevant, so a filtered result is not evidence of",
  "  absence. Re-run narrowed to a range if you need it.",
}, "\n")

--- ToolStart only fires for calls the model made itself, so a code_execution
--- inside a batch goes unseen, and a subagent's session is never counted (so
--- its nested calls are left alone).
local function track_parents()
  maki.api.create_autocmd({ "ToolStart", "ToolDone" }, {
    callback = function(ev)
      local data = ev.data
      if data.tool ~= "batch" and data.tool ~= "code_execution" then
        return
      end
      local counts = inflight[data.session_id] or { batch = 0, code_execution = 0 }
      inflight[data.session_id] = counts
      local step = ev.event == "ToolStart" and 1 or -1
      counts[data.tool] = math.max(0, counts[data.tool] + step)
    end,
  })
end

--- A script may parse what its nested call returns, and an elision marker in
--- the middle would break that parse.
local function may_filter(ctx)
  if ctx.origin ~= "nested" then
    return true
  end
  local counts = inflight[ctx.session_id]
  return counts ~= nil and counts.batch > 0 and counts.code_execution == 0
end

function M.install()
  maki.api.register_prompt_hint({ slot = "tool_usage", content = HINT })
  track_parents()
  for _, tool in ipairs(config.opts.filter_tools) do
    maki.api.set_slot("tool." .. tool .. ".output", function(prev, out, ctx)
      if config.opts.filter and may_filter(ctx) then
        local filtered = filter(out, ctx)
        if filtered then
          out.text = filtered
        end
      end
      return prev(out, ctx)
    end)
  end
end

return M
