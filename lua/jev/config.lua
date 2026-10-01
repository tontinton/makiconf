--- Options and counters shared by every jev feature. One table each, so
--- `/jev` toggles and reports without the features knowing about each other.

local M = {}

M.opts = {
  model = "jev-latest",
  url = "https://api.typesafe.ai/v1/systemone",

  -- Relevance filter on large tool output.
  filter = true,
  filter_tools = { "bash", "grep", "webfetch", "websearch", "glob", "list" },
  filter_min_score = 0.25,
  -- Errors are what the agent is looking for, so less of them goes.
  filter_min_score_error = 0.1,

  -- Jev picks which tool results the compaction summarizer reads in full.
  compact = true,
  -- Below this the result is collapsed even when the budget has room.
  compact_floor = 0.15,
  -- Multiplies the byte budget maki hands the prepare slot.
  compact_budget_scale = 1.0,
  -- Newest results the summarizer always reads, budget permitting.
  compact_pin_recent = 2,
  -- Coding-specific guidance appended to the summary prompt.
  compact_instructions = true,

  -- Compact on its own at a task boundary once the context is this full.
  -- Off by default: it spends a summary request the user did not ask for.
  boundary = false,
  boundary_at = 0.5,
  boundary_min_done = 0.85,

  -- Push the agent on when it stops early.
  stop = true,
  stop_threshold = 0.8,
}

M.stats = {
  requests = 0,
  errors = 0,
  input_tokens = 0,
  filtered = 0,
  filter_seen = 0,
  filter_saved = 0,
  compactions = 0,
  compact_spared = 0,
  compact_dropped = 0,
  boundary = 0,
  stop_checked = 0,
  stop_continued = 0,
}

function M.setup(user)
  for name, value in pairs(user or {}) do
    if M.opts[name] == nil then
      maki.log.warn("jev: unknown option " .. tostring(name))
    end
    M.opts[name] = value
  end
end

return M
