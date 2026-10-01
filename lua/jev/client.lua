--- One POST to TypeSafe's System One API. Every feature goes through `ask`,
--- so usage and failures are counted in one place.

local config = require("jev.config")

local ENV_KEYS = { "TYPESAFE_API_KEY", "TYPESAFE_AI" }
local HTTP_OK = 200
local DEFAULT_TIMEOUT = 20
local USD_PER_INPUT_MTOK = 0.042

local M = {}

local cached_key

function M.key()
  if cached_key == nil then
    cached_key = false
    for _, name in ipairs(ENV_KEYS) do
      local value = maki.uv.os_getenv(name)
      if value and value ~= "" then
        cached_key = value
        break
      end
    end
  end
  return cached_key or nil
end

function M.env_names()
  return table.concat(ENV_KEYS, " or ")
end

function M.cost()
  return config.stats.input_tokens * USD_PER_INPUT_MTOK / 1e6
end

--- `opts.retry` defaults to none: a hook the user is waiting on is better
--- off failing open than sitting through backoff.
function M.ask(state, questions, opts)
  opts = opts or {}
  local key = M.key()
  if not key then
    return nil, "no api key"
  end
  local stats = config.stats
  stats.requests = stats.requests + 1

  local res, err = maki.net.request(config.opts.url, {
    method = "POST",
    headers = { Authorization = "Bearer " .. key, ["Content-Type"] = "application/json" },
    body = maki.json.encode({ model = config.opts.model, state = state, questions = questions }),
    timeout = opts.timeout or DEFAULT_TIMEOUT,
    retry = opts.retry or 0,
  })
  if res and res.status ~= HTTP_OK then
    err = "http " .. tostring(res.status) .. ": " .. res.body:sub(1, 200)
  end
  local decoded = not err and maki.json.decode(res.body)
  local answers = decoded and decoded.answers
  if not answers then
    stats.errors = stats.errors + 1
    err = err or "no answers in response"
    maki.log.warn("jev: request failed: " .. tostring(err))
    return nil, err
  end
  local usage = decoded.usage
  if usage and usage.input_tokens then
    stats.input_tokens = stats.input_tokens + usage.input_tokens
  end
  return answers
end

function M.noul(answers, id)
  local answer = answers[id]
  return answer and answer.noul
end

return M
