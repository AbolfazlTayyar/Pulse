-- Market source registry and shared HTTP GET (ADR 0006, ADR 0021). Adapters live in
-- src/source/<name>.lua and are loaded on demand. Adapters never retry: retries need the
-- deadline and the lock TTL, which only the fetch leader has. They classify failures instead.
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local log = require("src.log")

local M = {}

-- The registry: adding a source is one adapter file plus its name here.
M.NAMES = { "coingecko", "binance", "kraken" }
local ADAPTERS = {}
for _, n in ipairs(M.NAMES) do ADAPTERS[n] = true end

-- Failure kinds an adapter reports in info.kind:
--   ok, timeout, connect, server_error (5xx), rate_limited (429), http_error (other status),
--   bad_payload (undecodable or wrong-shaped body).
M.RETRYABLE = { connect = true, server_error = true } -- ADR 0021; timeouts are never retried

local function classify_socket_error(err)
   err = tostring(err)
   if err:find("timeout", 1, true) or err:find("timed out", 1, true) then
      return "timeout"
   end
   return "connect"
end

-- GET url with timeout_ms applied to connect and to every read. Returns a table:
--   { kind, status, body, headers, http_ms, err }
-- kind is "ok" for any HTTP answer (the caller judges the status), else "timeout" / "connect".
-- Tests replace this function to stub the vendor.
function M.http_get(url, timeout_ms)
   local t0 = socket.gettime()
   local chunks = {}
   local timeout_s = timeout_ms / 1000
   local req = {
      url = url,
      method = "GET",
      sink = ltn12.sink.table(chunks),
      headers = { ["accept"] = "application/json", ["user-agent"] = "market-worker/0.1" },
      redirect = false,
   }
   local ok, status, headers
   if url:sub(1, 8) == "https://" then
      local https = require("ssl.https")
      https.TIMEOUT = timeout_s -- luasec applies its module timeout to every socket operation
      ok, status, headers = https.request(req)
   else
      http.TIMEOUT = timeout_s
      ok, status, headers = http.request(req)
   end
   local http_ms = math.floor((socket.gettime() - t0) * 1000 + 0.5)
   if not ok then
      return { kind = classify_socket_error(status), err = tostring(status), http_ms = http_ms }
   end
   return { kind = "ok", status = status, body = table.concat(chunks), headers = headers or {}, http_ms = http_ms }
end

-- Common status handling for adapters. Returns info for a non-200 answer, or nil when the
-- body should be parsed.
function M.status_info(name, res)
   if res.kind ~= "ok" then
      local detail = name .. ": " .. res.kind .. " (" .. tostring(res.err) .. ")"
      if res.kind == "timeout" then
         detail = name .. ": timeout after " .. res.http_ms .. "ms"
      end
      return { kind = res.kind, http_ms = res.http_ms, detail = detail }
   end
   local info = { status = res.status, http_ms = res.http_ms }
   if res.status == 200 then
      return nil, info
   end
   info.detail = name .. ": HTTP " .. tostring(res.status)
   if res.status == 429 then
      info.kind = "rate_limited"
      info.retry_after = res.headers["retry-after"]
   elseif type(res.status) == "number" and res.status >= 500 then
      info.kind = "server_error"
   else
      info.kind = "http_error"
   end
   return info
end

-- Performs the request and logs it. Returns res, info-or-nil (see status_info).
function M.request(name, url, timeout_ms)
   log.debug("vendor_request", { source = name, url = url })
   local res = M.http_get(url, timeout_ms)
   local failed, info = M.status_info(name, res)
   info = failed or info
   log.info("vendor_call", { source = name, status = res.status, kind = info.kind or "ok", http_ms = res.http_ms })
   return res, failed, info
end

function M.is_known(name)
   return ADAPTERS[name] == true
end

-- Adapter instance for a source: { name, fetch(symbols, quote, timeout_ms) -> rows, errors, info,
-- effective_quote(quote) -> the quote actually priced (ADR 0024), supports(symbol, quote) -> bool:
-- false means the adapter would answer UNKNOWN_SYMBOL without asking the vendor }.
-- base_url overrides the adapter's default (SOURCE_URL).
function M.get(name, base_url)
   if not ADAPTERS[name] then
      return nil, "unknown market source " .. tostring(name)
   end
   return require("src.source." .. name).new(base_url)
end

return M
