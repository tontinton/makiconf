--- Compaction steered by Jev.
---
--- Before summarizing, maki collapses older tool results to `[tool result]`
--- so the summarizer reads only the newest ones in full, picked by recency
--- within a byte budget. Recency is a poor proxy late in a session: the spec
--- fetched an hour ago still matters, the twentieth `cargo test` run does not.
--- Here Jev scores every result against the goal and a timeline of what came
--- after it, and the budget goes to the results the remaining work needs.
---
--- Also appends coding-specific summary instructions, and optionally compacts
--- on its own at a task boundary instead of waiting for the threshold to hit
--- mid-task.

local client = require("jev.client")
local config = require("jev.config")
local context = require("jev.context")

local EXCERPT_BYTES = 1400
-- Kept without asking: cheaper to keep than to ask about.
local SMALL_RESULT_BYTES = 512
local QUESTION_BYTES_PER_REQUEST = 40 * 1024
local TIMELINE_BYTES = 16 * 1024
local CALL_BYTES = 200
local REPLY_BYTES = 3000
local NEUTRAL_SCORE = 0.5
local PINNED = math.huge

-- Wording tested against a hand-built session: without the `timeline` clause in
-- `false`, fixed errors and re-read files scored as high as the live spec.
local QUESTION = "Does the agent still need the text of `result`, the output of `call`, to finish `goal`?"
local CRITERIA = {
  ["true"] = "It holds something the agent will rely on and cannot cheaply get back: "
    .. "an unfixed error, a spec or fact, file contents it has not re-read since, or a constraint",
  ["false"] = "A later entry in `timeline` superseded it (same file edited or read again, "
    .. "same command run again, error fixed), it was a dead end, or it is routine output "
    .. "with nothing left to act on",
}

local SUMMARY_INSTRUCTIONS = table.concat({
  "- Keep verbatim every file path, symbol name, command, and exact error message the remaining work depends on.",
  "- Keep every requirement, constraint, and preference the user stated, in their words.",
  "- List what was tried and failed, and why, so it is not tried again.",
  "- Say which checks (build, tests, lint) last passed or failed, and on what.",
  "- `[tool result]` marks output left out as stale or irrelevant. Do not guess what it said.",
}, "\n")

local CONTINUE = "Re-read a file before editing it: the summary does not hold current file contents."

local DONE_QUESTION = "Does `final_reply` report that the work asked for in `goal` is finished, "
  .. "with nothing left pending and no question for the user?"

local M = {}

local function timeline(results)
  local lines, bytes, first = {}, 0, 1
  for i = #results, 1, -1 do
    local r = results[i]
    local line = string.format(
      "[%d] %s -> %d bytes",
      r.index,
      context.describe_call(r.tool, r.input, CALL_BYTES),
      r.bytes
    )
    if bytes + #line > TIMELINE_BYTES then
      first = i + 1
      break
    end
    lines[i] = line
    bytes = bytes + #line + 1
  end
  local out = {}
  if first > 1 then
    out[1] = string.format("[%d older calls omitted]", first - 1)
  end
  for i = first, #results do
    out[#out + 1] = lines[i]
  end
  return table.concat(out, "\n")
end

local function question_for(r)
  local excerpt = context.clip(r.text or "", EXCERPT_BYTES)
  return {
    type = "noul",
    instructions = {
      question = QUESTION,
      call = string.format("[%d] %s (%d bytes)", r.index, context.describe_call(r.tool, r.input, CALL_BYTES), r.bytes),
      result = excerpt,
    },
    criteria = CRITERIA,
  }, #excerpt
end

--- Pinned and small results score `PINNED` so they sort first and are never
--- sent; everything else is scored by Jev in parallel batches.
local function score(prep, state)
  local results, scores = prep.results, {}
  local pin_from = #results - config.opts.compact_pin_recent + 1
  local batches, batch, bytes = {}, {}, 0
  for i, r in ipairs(results) do
    if i >= pin_from or r.bytes <= SMALL_RESULT_BYTES then
      scores[i] = PINNED
    else
      local question, size = question_for(r)
      if bytes + size > QUESTION_BYTES_PER_REQUEST and next(batch) then
        batches[#batches + 1] = batch
        batch, bytes = {}, 0
      end
      batch["r" .. i] = question
      bytes = bytes + size
    end
  end
  if next(batch) then
    batches[#batches + 1] = batch
  end
  if #batches == 0 then
    return nil
  end

  local jobs = {}
  for n, questions in ipairs(batches) do
    jobs[n] = function()
      return client.ask(state, questions)
    end
  end
  local answered = 0
  for _, result in ipairs(maki.async.gather(jobs)) do
    if result.ok and result.value then
      answered = answered + 1
      for id, answer in pairs(result.value) do
        local i = tonumber(id:sub(2))
        if i and answer.noul then
          scores[i] = answer.noul
        end
      end
    end
  end
  if answered == 0 then
    return nil
  end
  return scores
end

--- Highest score first, newest first among equals, each kept while it fits.
--- A result too big for what is left is collapsed and the rest go on, the
--- same rule maki's own pick follows.
local function pick(prep, scores)
  local results = prep.results
  local order = {}
  for i = 1, #results do
    order[i] = i
  end
  table.sort(order, function(a, b)
    local sa, sb = scores[a] or NEUTRAL_SCORE, scores[b] or NEUTRAL_SCORE
    if sa ~= sb then
      return sa > sb
    end
    return a > b
  end)

  local budget = math.floor(prep.budget * config.opts.compact_budget_scale)
  local collapse = {}
  for _, i in ipairs(order) do
    local s = scores[i] or NEUTRAL_SCORE
    if s >= config.opts.compact_floor and results[i].bytes <= budget then
      budget = budget - results[i].bytes
    else
      collapse[#collapse + 1] = i
    end
  end
  table.sort(collapse)
  return collapse
end

local function as_set(list)
  local set = {}
  for _, i in ipairs(list or {}) do
    set[i] = true
  end
  return set
end

local function prepare(prep, ctx)
  local results = prep.results or {}
  if #results <= config.opts.compact_pin_recent then
    return nil
  end
  local state = {
    goal = context.goal(ctx.session_id) or "unknown",
    timeline = timeline(results),
  }
  local scores = score(prep, state)
  if not scores then
    return nil
  end
  local collapse = pick(prep, scores)

  local host, ours = as_set(prep.collapse), as_set(collapse)
  local spared, dropped = 0, 0
  for i = 1, #results do
    if host[i] and not ours[i] then
      spared = spared + 1
    elseif ours[i] and not host[i] then
      dropped = dropped + 1
    end
  end
  local stats = config.stats
  stats.compactions = stats.compactions + 1
  stats.compact_spared = stats.compact_spared + spared
  stats.compact_dropped = stats.compact_dropped + dropped
  maki.log.info(string.format(
    "jev compact: %d results, collapsed %d (maki would have %d), spared %d old, dropped %d recent",
    #results,
    #collapse,
    #(prep.collapse or {}),
    spared,
    dropped
  ))
  return collapse
end

local function append(existing, extra)
  if existing and existing:find("%S") then
    return existing .. "\n" .. extra
  end
  return extra
end

local function last_reply(session_id)
  local msgs = context.messages(session_id, 1)
  local msg = msgs and msgs[#msgs]
  if not msg or msg.role ~= "assistant" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(msg.content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text
    end
  end
  local text = table.concat(parts, "\n")
  return text:find("%S") and context.clip_tail(text, REPLY_BYTES) or nil
end

--- Compacting between tasks loses less than compacting mid-task, and the
--- user is reading the answer anyway, so the summary request costs no wait.
local function on_turn_end(ev)
  local data = ev.data
  local opts = config.opts
  if not opts.boundary or data.reason ~= "finished" or (data.context_window or 0) == 0 then
    return
  end
  local fill = data.context_size / data.context_window
  if fill < opts.boundary_at or maki.session.current() ~= data.session_id then
    return
  end
  local reply = last_reply(data.session_id)
  if not reply then
    return
  end
  local answers = client.ask(
    { goal = context.goal(data.session_id) or "unknown", final_reply = reply },
    { done = { type = "noul", instructions = DONE_QUESTION } }
  )
  local done = answers and client.noul(answers, "done")
  if not done or done < opts.boundary_min_done then
    return
  end
  config.stats.boundary = config.stats.boundary + 1
  maki.log.info(string.format("jev boundary: task done (%.2f) at %.0f%% context, compacting", done, fill * 100))
  maki.notify(string.format("task done at %.0f%% context, compacting", fill * 100), "info", { title = "jev" })
  maki.api.run_command("/compact")
end

function M.install()
  maki.api.set_slot("agent.compact.prepare", function(prev, prep, ctx)
    if config.opts.compact then
      local collapse = prepare(prep, ctx)
      if collapse then
        prep.collapse = collapse
      end
    end
    return prev(prep, ctx)
  end)

  maki.api.set_slot("agent.compact.before", function(prev, before, ctx)
    if config.opts.compact_instructions then
      before.instructions = append(before.instructions, SUMMARY_INSTRUCTIONS)
      before.continue = append(before.continue, CONTINUE)
    end
    return prev(before, ctx)
  end)

  maki.api.create_autocmd("TurnEnd", { callback = on_turn_end })
end

return M
