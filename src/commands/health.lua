-- health: health.v1 (ADR 0022). ok is a real Redis PING; the source block is informational.
-- Never calls the vendor, never touches the rate limit. Redis down: full body, exit 3.
local json = require("src.vendor.dkjson")
local socket = require("socket")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local limiter = require("src.limiter")

local M = {}

M.VERSION = "0.1.0"

local null = json.null

local function source_block(name, last_fetch, age, calls, cooldown)
   return { name = name, last_fetch_unix = last_fetch, last_fetch_age_s = age, vendor_calls = calls,
      cooldown_active = cooldown }
end

function M.run(_, ctx)
   local cfg = ctx.config
   local name = cfg.market_source
   local now = os.time()
   local body = {
      ok = false,
      schema = "health.v1",
      as_of_unix = now,
      process = { ok = true, lua = _VERSION, version = M.VERSION },
      source = source_block(name, null, null, null, null),
   }

   local t0 = socket.gettime()
   local client, err = redis.from_context(ctx)
   local pong
   if client then
      pong, err = client:call_idempotent("PING")
   end
   if pong ~= "PONG" then
      body.redis = { ok = false, error = tostring(err or "unexpected PING reply") }
      return body, 3
   end
   body.ok = true
   body.redis = { ok = true, latency_ms = math.floor((socket.gettime() - t0) * 1000 + 0.5) }

   -- Informational: a failure here doesn't make the worker unhealthy, it leaves the value null.
   local last = snapshot.get_last_fetch(client, name)
   local calls = snapshot.get_vendor_calls(client, name)
   local cooldown = limiter.cooldown_active(client, name)
   local last_fetch = last or null
   body.source = source_block(name, last_fetch, last and math.max(0, now - last) or null, calls or null,
      cooldown == nil and null or cooldown)
   return body, 0
end

return M
