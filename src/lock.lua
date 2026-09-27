-- Single-flight lock per source (ADR 0008, ADR 0018): only the holder calls the vendor. The
-- lock expires on its own after ttl_ms, so a killed process can't hold it forever, and a random
-- token makes sure a late release never deletes someone else's lock.
local redis = require("src.redis_client")
local log = require("src.log")

local M = {}

-- Deletes the key only if it still holds our token, atomically.
local RELEASE = [[
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
]]

function M.key(source)
   return "mkt:lock:" .. source
end

-- 128 bits from the kernel RNG. Not math.random: many processes start in the same millisecond,
-- so any time-based seed would hand out the same token twice.
function M.new_token()
   local f = io.open("/dev/urandom", "rb")
   if not f then
      return nil, "no random source (/dev/urandom)"
   end
   local bytes = f:read(16)
   f:close()
   if not bytes or #bytes ~= 16 then
      return nil, "short read from /dev/urandom"
   end
   return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- token when we got the lock, false when someone else holds it, nil, err on Redis failure.
-- SET NX is never retried (ADR 0021): if the outcome is unknown, the lock we may hold expires.
function M.acquire(client, source, ttl_ms)
   local token, terr = M.new_token()
   if not token then
      return nil, terr
   end
   local reply, err = client:call("SET", M.key(source), token, "NX", "PX", ttl_ms)
   if reply == nil then
      return nil, err
   end
   if reply == "OK" then
      log.info("lock_acquired", { source = source, ttl_ms = ttl_ms })
      return token
   end
   if reply == redis.null then
      log.debug("lock_busy", { source = source })
      return false
   end
   return nil, "unexpected reply to SET NX"
end

-- true when released, false when the lock was no longer ours (expired, maybe taken over),
-- nil, err on Redis failure. Compare-and-delete is idempotent, so it may be retried.
function M.release(client, source, token)
   local n, err = client:eval(RELEASE, { M.key(source) }, { token }, { idempotent = true })
   if n == nil then
      return nil, err
   end
   if n == 1 then
      log.info("lock_released", { source = source })
      return true
   end
   log.warn("lock_lost", { source = source })
   return false
end

-- ms left on the lock (0 when it is gone), for the HTTP retry rule in ADR 0021.
function M.remaining_ttl_ms(client, source)
   local ms, err = client:call_idempotent("PTTL", M.key(source))
   if ms == nil then
      return nil, err
   end
   if math.type(ms) ~= "integer" or ms < 0 then
      return 0
   end
   return ms
end

return M
