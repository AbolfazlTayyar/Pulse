-- Test-only vendor stub, loaded with `lua -l tests.support.fixture_http market.lua ...` (from
-- the repo root). It replaces src.source.http_get, so no HTTP server is ever started.
--
--   SOURCE_URL=http://fixture/<path under tests/fixtures>   the file served as the body
--   FIXTURE_STATUS=200            status per request, comma-separated for sequences ("500,200");
--                                 the last one repeats. "timeout" / "connect" simulate socket errors.
--   FIXTURE_RETRY_AFTER=12        Retry-After header
--   FIXTURE_DELAY_MS=300          simulated latency (real sleep)
--
-- Any other URL goes to the real network.
local source = require("src.source")
local socket = require("socket")

local real = source.http_get
local statuses = {}
for s in (os.getenv("FIXTURE_STATUS") or "200"):gmatch("[^,]+") do statuses[#statuses + 1] = s end
local n = 0

source.http_get = function(url, timeout_ms)
   local file = url:match("^http://fixture/([^?]-%.%a+)")
   if not file then
      return real(url, timeout_ms)
   end
   n = n + 1
   local status = statuses[math.min(n, #statuses)]
   local delay = tonumber(os.getenv("FIXTURE_DELAY_MS") or "0")
   if delay > 0 then socket.sleep(math.min(delay, timeout_ms) / 1000) end
   if status == "timeout" then
      return { kind = "timeout", err = "timeout", http_ms = timeout_ms }
   elseif status == "connect" then
      return { kind = "connect", err = "connection refused", http_ms = 1 }
   end
   local f = assert(io.open("tests/fixtures/" .. file, "rb"))
   local body = f:read("a")
   f:close()
   return {
      kind = "ok",
      status = math.tointeger(tonumber(status)),
      body = body,
      headers = { ["retry-after"] = os.getenv("FIXTURE_RETRY_AFTER") },
      http_ms = delay,
   }
end

return true
