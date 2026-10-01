--- What the agent is working on, for the `state` of every question. Builders
--- report the goal in state as the biggest single lever on Jev's accuracy, and
--- the agent's stated intent as what stops a filter eliding what it was about
--- to read.
---
--- Goals are recorded as user messages arrive. After a `/reload` the table is
--- empty, so a miss falls back to scanning the live transcript once.

local truncate = require("maki.truncate")

local MAX_GOALS = 3
local GOAL_BYTES = 1500
local INTENT_BYTES = 800
local SCAN_MESSAGES = 80
local MAX_WORK_LINES = 40
local WORK_CALL_BYTES = 160
local ARG_KEYS = { "command", "pattern", "query", "url", "path", "file_path", "description" }

local M = {}

local goals = {}
local latest

local function clip(text, max_bytes)
  return truncate(text, math.huge, max_bytes)
end

local function clip_tail(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  local cut = #text - max_bytes + 1
  while cut <= #text and text:find("^[\128-\191]", cut) do
    cut = cut + 1
  end
  return "[...] " .. text:sub(cut)
end

local function one_line(text)
  return (text:gsub("%s+", " "))
end

local function blocks_text(msg, kind)
  local parts = {}
  for _, block in ipairs(msg.content or {}) do
    if block.type == kind and block.text then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "\n")
end

local function is_user_turn(msg)
  return msg.role == "user" and msg.kind == "turn" and not msg.hidden and blocks_text(msg, "text") ~= ""
end

local function render(list)
  if #list == 1 then
    return list[1]
  end
  local parts = {}
  for i = 1, #list - 1 do
    parts[#parts + 1] = "Earlier request: " .. list[i]
  end
  parts[#parts + 1] = "Latest request: " .. list[#list]
  return table.concat(parts, "\n\n")
end

function M.messages(session_id, last)
  local ok, msgs = pcall(maki.session.messages, { session = session_id, last = last })
  if ok and type(msgs) == "table" then
    return msgs
  end
  return nil
end

function M.record(session_id, text)
  if not session_id or not text or not text:find("%S") then
    return
  end
  local list = goals[session_id] or {}
  list[#list + 1] = clip(text, GOAL_BYTES)
  if #list > MAX_GOALS then
    table.remove(list, 1)
  end
  goals[session_id] = list
  latest = list
end

local function scan_goals(session_id)
  local msgs = M.messages(session_id, SCAN_MESSAGES)
  if not msgs then
    return nil
  end
  local found = {}
  for i = #msgs, 1, -1 do
    if is_user_turn(msgs[i]) then
      table.insert(found, 1, clip(blocks_text(msgs[i], "text"), GOAL_BYTES))
      if #found >= MAX_GOALS then
        break
      end
    end
  end
  return #found > 0 and found or nil
end

--- A subagent's tool calls carry its own session id, which never saw a user
--- message, so a miss there borrows the newest goal recorded anywhere.
function M.goal(session_id)
  if session_id and goals[session_id] == nil then
    goals[session_id] = scan_goals(session_id) or false
  end
  local list = (session_id and goals[session_id]) or latest
  return list and render(list) or nil
end

--- The newest assistant message is the one holding the call, so its text is
--- what the agent said it was about to do. With no text, the tail of its
--- thinking is the closest thing.
function M.intent(session_id)
  local msgs = M.messages(session_id, 3)
  for i = #(msgs or {}), 1, -1 do
    local msg = msgs[i]
    if msg.role == "assistant" then
      local text = blocks_text(msg, "text")
      if text:find("%S") then
        return clip_tail(text, INTENT_BYTES)
      end
      local thinking = blocks_text(msg, "thinking")
      return thinking:find("%S") and clip_tail(thinking, INTENT_BYTES) or nil
    end
  end
  return nil
end

function M.describe_call(tool, input, max_bytes)
  local parts = { tool or "tool" }
  if type(input) == "table" then
    for _, name in ipairs(ARG_KEYS) do
      local value = input[name]
      if type(value) == "string" and value ~= "" then
        parts[#parts + 1] = name .. "=" .. one_line(value)
      end
    end
  end
  return clip(table.concat(parts, " "), max_bytes)
end

--- Every call since the newest user message, one line each, errors marked.
function M.work_since_request(session_id)
  local msgs = M.messages(session_id, SCAN_MESSAGES)
  if not msgs then
    return nil
  end
  local start = 1
  for i = #msgs, 1, -1 do
    if is_user_turn(msgs[i]) then
      start = i + 1
      break
    end
  end
  local failed = {}
  for i = start, #msgs do
    for _, block in ipairs(msgs[i].content or {}) do
      if block.type == "tool_result" and block.is_error then
        failed[block.tool_use_id] = true
      end
    end
  end
  local lines = {}
  for i = start, #msgs do
    for _, block in ipairs(msgs[i].content or {}) do
      if block.type == "tool_use" then
        local line = M.describe_call(block.name, block.input, WORK_CALL_BYTES)
        lines[#lines + 1] = failed[block.id] and (line .. " (error)") or line
      end
    end
  end
  local from = math.max(1, #lines - MAX_WORK_LINES + 1)
  return table.concat(lines, "\n", from, #lines), #lines
end

M.clip = clip
M.clip_tail = clip_tail

return M
