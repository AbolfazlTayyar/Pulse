-- Reads and validates every env var once at startup (CLAUDE.md "Environment variables",
-- ADR 0017, ADR 0021 "Explicit configuration"). Returns an immutable table, or nil, code, detail.
-- Never raises, and REDIS_PASSWORD never appears in an error message.
local M = {}

local SOURCES = { coingecko = true, binance = true, kraken = true }
local LOG_LEVELS = { debug = true, info = true, warn = true, error = true }

-- name, config key, default: every numeric setting must be a positive integer.
local INTEGERS = {
   { "REDIS_PORT", "redis_port", 6379 },
   { "REDIS_TIMEOUT_MS", "redis_timeout_ms", 200 },
   { "SOURCE_TIMEOUT_MS", "source_timeout_ms", 2000 },
   { "DEADLINE_MS", "deadline_ms", 4000 },
   { "SNAPSHOT_FRESH_S", "snapshot_fresh_s", 5 },
   { "SNAPSHOT_KEEP_S", "snapshot_keep_s", 3600 },
   { "LOCK_TTL_MS", "lock_ttl_ms", 3000 },
   { "RATE_LIMIT_WINDOW_S", "rate_limit_window_s", 10 },
   { "RATE_LIMIT_PER_WINDOW", "rate_limit_per_window", 5 },
   { "MAX_CONCURRENT_UPSTREAM", "max_concurrent_upstream", 1 },
   { "CACHE_MAX_ENTRIES", "cache_max_entries", 256 },
   { "CACHE_MAX_BYTES", "cache_max_bytes", 1048576 },
   { "CONVERT_SCALE", "convert_scale", 8 },
}

local function bad(detail)
   return nil, "BAD_CONFIG", detail
end

-- Unset and empty both mean "not set".
local function read(getenv, name)
   local v = getenv(name)
   if v == nil or v == "" then
      return nil
   end
   return v
end

local function positive_int(s)
   -- At most 9 digits: every setting fits, and nothing can overflow.
   if type(s) ~= "string" or not s:match("^[1-9]%d?%d?%d?%d?%d?%d?%d?%d?$") then
      return nil
   end
   return math.tointeger(tonumber(s))
end

local function freeze(t)
   return setmetatable({}, {
      __index = t,
      __newindex = function(_, k) error("config is read-only (tried to set " .. tostring(k) .. ")", 2) end,
      __pairs = function() return next, t, nil end,
      __metatable = false,
   })
end

local function load_config(getenv)
   getenv = getenv or os.getenv
   local c = {}

   local host = read(getenv, "REDIS_HOST")
   if not host then
      return bad("REDIS_HOST is required")
   end
   if host:find("[%s%c]") then
      return bad("REDIS_HOST must not contain whitespace or control characters")
   end
   c.redis_host = host
   c.redis_password = read(getenv, "REDIS_PASSWORD")

   for _, spec in ipairs(INTEGERS) do
      local name, key, default = spec[1], spec[2], spec[3]
      local raw = read(getenv, name)
      if raw == nil then
         c[key] = default
      else
         local n = positive_int(raw)
         if not n then
            return bad(name .. " must be a positive integer")
         end
         c[key] = n
      end
   end

   if c.redis_port > 65535 then
      return bad("REDIS_PORT must be at most 65535")
   end
   if not (c.source_timeout_ms < c.lock_ttl_ms and c.lock_ttl_ms < c.deadline_ms) then
      return bad("need SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS")
   end
   if c.snapshot_fresh_s > c.snapshot_keep_s then
      return bad("need SNAPSHOT_FRESH_S <= SNAPSHOT_KEEP_S")
   end
   if c.max_concurrent_upstream ~= 1 then
      return bad("MAX_CONCURRENT_UPSTREAM: only 1 is supported, see ADR 0018 "
         .. "(the per-source lock allows one in-flight vendor call)")
   end
   if c.convert_scale > 18 then
      return bad("CONVERT_SCALE must be at most 18")
   end

   c.market_source = read(getenv, "MARKET_SOURCE") or "coingecko"
   if not SOURCES[c.market_source] then
      return bad("MARKET_SOURCE must be one of coingecko, binance, kraken")
   end

   c.market_quote = read(getenv, "MARKET_QUOTE") or "USD"
   if not c.market_quote:match("^[A-Z][A-Z][A-Z][A-Z]?[A-Z]?$") then
      return bad("MARKET_QUOTE must be a currency code of 3-5 uppercase letters, e.g. USD")
   end

   c.source_url = read(getenv, "SOURCE_URL")
   if c.source_url and not c.source_url:match("^https?://[^%s%c]+$") then
      return bad("SOURCE_URL must be an http:// or https:// URL")
   end

   c.log_level = read(getenv, "LOG_LEVEL") or "info"
   if not LOG_LEVELS[c.log_level] then
      return bad("LOG_LEVEL must be one of debug, info, warn, error")
   end

   return freeze(c)
end

-- getenv defaults to os.getenv; tests pass a fake.
function M.load(getenv)
   local ok, c, code, detail = pcall(load_config, getenv)
   if not ok then
      return bad("cannot read configuration")
   end
   return c, code, detail
end

return M
