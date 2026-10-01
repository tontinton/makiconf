--- Pushes the agent on when it ends its turn early: announcing a next step
--- and stopping, or leaving errors it could fix without saying why.
---
--- Used as a veto, never as proof of completion: a confident "done" or "needs
--- the user" always lets the turn end, and only a confident early stop pushes.
--- One push per user message, on top of maki's own cap.

local client = require("jev.client")
local config = require("jev.config")
local context = require("jev.context")

local REQUEST_TIMEOUT = 8
local REPLY_BYTES = 3000
-- One round trip is a direct answer with no tool call: nothing to cut short.
local MIN_TURNS = 2
local MAX_PUSHES = 1

local QUESTION = {
  type = "choice",
  instructions = "A coding agent ended its turn with `final_reply` after doing `work` for the "
    .. "request in `goal`. Which describes `final_reply`?",
  criteria = {
    done = "Reports that the requested work is finished, answers the question, or explains why "
      .. "it cannot be done",
    needs_user = "Asks the user a question, for a decision, or for information or permission the "
      .. "agent needs before going on",
    announced = "Says the agent will now take a next step (for example 'Now I'll update the tests' "
      .. "or 'Let me fix that'), but stops without the work of that step appearing in `work`",
    left_failing = "Admits that errors or failing tests remain that the agent could fix itself, and "
      .. "stops without saying why it is leaving them",
  },
}

local NUDGES = {
  announced = "[jev] You ended your turn right after saying you would take a next step. "
    .. "Take that step now, or say why you stopped.",
  left_failing = "[jev] You ended your turn with errors or failing tests you could still fix. "
    .. "Fix them, or say why you are leaving them.",
}

local M = {}

local pushes = {}

function M.reset(session_id)
  if session_id then
    pushes[session_id] = nil
  end
end

local function nudge_for(stop, session_id)
  local work = context.work_since_request(session_id)
  local answers = client.ask({
    goal = context.goal(session_id) or "unknown",
    work = (work and work ~= "") and work or "no tool calls",
    final_reply = context.clip_tail(stop.last_message, REPLY_BYTES),
  }, { verdict = QUESTION }, { timeout = REQUEST_TIMEOUT })
  local verdict = answers and answers.verdict
  if not verdict or not NUDGES[verdict.choice] then
    return nil
  end
  local p = (verdict.probabilities or {})[verdict.choice] or 0
  maki.log.info(string.format("jev stop: %s (%.2f, confidence %.2f)", verdict.choice, p, verdict.confidence or 0))
  if p < config.opts.stop_threshold then
    return nil
  end
  return NUDGES[verdict.choice]
end

function M.install()
  maki.api.set_slot("agent.stop", function(prev, stop, ctx)
    -- The innermost default hands back its own arguments, so `reason` is only
    -- a verdict when `value` is gone.
    local value, reason = prev(stop, ctx)
    if value == nil and reason ~= nil then
      return value, reason
    end
    local sid = ctx.session_id
    local eligible = config.opts.stop
      and sid
      and not (value and value.continue)
      and stop.reason == "finished"
      and not ctx.task_id
      and (stop.num_turns or 0) >= MIN_TURNS
      and (pushes[sid] or 0) < MAX_PUSHES
      and type(stop.last_message) == "string"
      and stop.last_message:find("%S")
    if not eligible then
      return value
    end
    config.stats.stop_checked = config.stats.stop_checked + 1
    local nudge = nudge_for(stop, sid)
    if not nudge then
      return value
    end
    pushes[sid] = (pushes[sid] or 0) + 1
    config.stats.stop_continued = config.stats.stop_continued + 1
    return { continue = nudge }
  end)
end

return M
