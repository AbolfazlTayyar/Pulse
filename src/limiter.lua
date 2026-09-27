-- Shared vendor-call cap and 429 cooldown (ADR 0012, ADR 0011). Only the lock holder calls
-- take(), so the limit counts real vendor calls, not invocations.
local log = require("src.log")

local M = {}

M.DEFAULT_COOLDOWN_S = 30 -- ADR 0017: when the vendor sends no usable Retry-After
M.MAX_COOLDOWN_S = 3600   -- a hostile or broken header can't silence the vendor for longer

-- ADR 0012: one atomic round-trip; the first INCR in a window sets its expiry.
local TAKE = [[
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
return n
]]

function M.window_key(source, window_s, now)
   return "mkt:rl:" .. source .. ":" .. string.format("%d", now // window_s)
end

function M.cooldown_key(source)
   return "mkt:cooldown:" .. source
end

-- allowed (bool), count; or nil, err on Redis failure. Never retried: a retry could count one
-- call twice (ADR 0021). now defaults to os.time() and is injectable for tests.
function M.take(client, source, window_s, limit, now)
   now = now or os.time()
   local n, err = client:eval(TAKE, { M.window_key(source, window_s, now) }, { window_s })
   if n == nil then
      return nil, err
   end
   if math.type(n) ~= "integer" then
      return nil, "unexpected reply from rate-limit script"
   end
   if n > limit then
      log.warn("rate_limited", { source = source, count = n, limit = limit })
      return false, n
   end
   return true, n
end

-- Retry-After as whole seconds. Only the delta-seconds form is used; the HTTP-date form
-- ("Wed, 21 Oct 2026 07:28:00 GMT") would need clock-skew handling against the vendor's clock,
-- so it falls back to the default like a missing or unparseable header.
function M.cooldown_seconds(retry_after)
   if type(retry_after) == "string" then
      local digits = retry_after:match("^%s*(%d+)%s*$")
      if digits and #digits <= 6 then
         local s = math.tointeger(tonumber(digits))
         return math.max(1, math.min(s, M.MAX_COOLDOWN_S))
      end
   end
   return M.DEFAULT_COOLDOWN_S
end

-- Sets mkt:cooldown:{source} after a vendor 429. Returns ttl_s, or nil, err. SET is idempotent.
function M.set_cooldown(client, source, retry_after)
   local ttl = M.cooldown_seconds(retry_after)
   local ok, err = client:call_idempotent("SET", M.cooldown_key(source), "1", "EX", ttl)
   if ok == nil then
      return nil, err
   end
   log.warn("cooldown_set", { source = source, ttl_s = ttl })
   return ttl
end

-- active (bool), ttl_s; or nil, err.
function M.cooldown_active(client, source)
   local ttl, err = client:call_idempotent("TTL", M.cooldown_key(source))
   if ttl == nil then
      return nil, err
   end
   if math.type(ttl) ~= "integer" or ttl == -2 then
      return false, 0
   end
   -- -1 (no expiry) can't come from set_cooldown; still treat it as active, never as a free pass.
   ttl = math.max(ttl, 0)
   log.warn("cooldown_active", { source = source, ttl_s = ttl })
   return true, ttl
end

return M
