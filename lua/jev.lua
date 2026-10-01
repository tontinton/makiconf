--- TypeSafe Jev inside maki: fast, calibrated yes/no and multiple-choice
--- judgments at the points where the agent loop makes a decision.
---
---   filter    drop irrelevant blocks of large tool output before history
---   compact   Jev picks which tool results the compaction summary reads
---   boundary  compact on its own once a task is done (off by default)
---   stop      push the agent on when it stops early
---
--- Needs TYPESAFE_API_KEY (or TYPESAFE_AI). Without it nothing is installed.
---
---   require("jev").setup({ boundary = true, stop_threshold = 0.9 })
---
--- Options are in `jev/config.lua`. `/jev` shows stats, `/jev <feature> on|off`
--- toggles one for the session.

local Toast = require("maki.toast")
local client = require("jev.client")
local config = require("jev.config")
local context = require("jev.context")
local stop = require("jev.stop")

local FEATURES = { "filter", "compact", "boundary", "stop" }
local STATUS_SECS = 10

local M = {}

local installed = false

local function install()
  maki.api.set_slot("agent.user_message", function(prev, msg, ctx)
    if not ctx.task_id then
      context.record(ctx.session_id, msg.text)
      stop.reset(ctx.session_id)
    end
    return prev(msg, ctx)
  end)
  require("jev.filter").install()
  require("jev.compact").install()
  stop.install()
end

--- The toast is narrow, so each line stays short.
local function status()
  local opts, s = config.opts, config.stats
  local on = {}
  for _, name in ipairs(FEATURES) do
    if opts[name] then
      on[#on + 1] = name
    end
  end
  return table.concat({
    "on: " .. (#on > 0 and table.concat(on, " ") or "nothing"),
    string.format("api: %d req, %.0fk tok, $%.4f, %d err", s.requests, s.input_tokens / 1000, client.cost(), s.errors),
    string.format("filter: cut %d/%d outputs, -%.0f KB", s.filtered, s.filter_seen, s.filter_saved / 1024),
    string.format(
      "compact: %d runs, +%d old -%d new, %d auto",
      s.compactions,
      s.compact_spared,
      s.compact_dropped,
      s.boundary
    ),
    string.format("stop: pushed %d/%d", s.stop_continued, s.stop_checked),
  }, "\n")
end

local function command(args)
  if not client.key() then
    maki.ui.flash("jev: " .. client.env_names() .. " not set, nothing installed (set it, then /reload)")
    return
  end
  local feature, state = args.fargs[1], args.fargs[2]
  if not feature then
    Toast.show(status(), { title = "jev", timeout_secs = STATUS_SECS })
    return
  end
  if config.opts[feature] == nil or type(config.opts[feature]) ~= "boolean" then
    maki.ui.flash("jev: unknown feature " .. feature .. " (" .. table.concat(FEATURES, ", ") .. ")")
    return
  end
  if state == "on" or state == "off" then
    config.opts[feature] = state == "on"
  else
    config.opts[feature] = not config.opts[feature]
  end
  maki.ui.flash("jev " .. feature .. " " .. (config.opts[feature] and "on" or "off"))
end

function M.setup(user)
  config.setup(user)
  if installed then
    return
  end
  installed = true
  maki.api.register_command({
    name = "/jev",
    description = "Jev: show stats, or toggle a feature (" .. table.concat(FEATURES, "|") .. ") [on|off]",
    nargs = "*",
    handler = command,
  })
  -- A slot with no layers never crosses into Lua, so without the key this
  -- plugin costs one env lookup for the whole session.
  if client.key() then
    install()
  else
    maki.log.info("jev: " .. client.env_names() .. " not set, no hooks installed")
  end
end

return M
