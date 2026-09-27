-- The ONLY module that writes to stdout (ADR 0002): one JSON object per line, flushed.
local json = require("src.vendor.dkjson")

local M = {}

-- Fixed key order for the top level of every body, so output is stable and readable.
-- dkjson applies one order list to every object, so item and leg fields are listed too.
local KEY_ORDER = {
   "id", "symbol", "ok", "code", "detail", "schema",
   "quote", "price", "volume_24h", "change_24h_pct", "as_of_unix", "stale",
   "process", "redis", "lua", "version", "source", "from", "to", "amount", "result", "rate", "items", "errors", "legs",
   "name", "latency_ms", "error", "last_fetch_unix", "last_fetch_age_s",
   "vendor_calls", "cooldown_active", "cache", "partial", "redis_ms", "http_ms", "meta",
}

local stream = io.stdout

-- Tests swap in a temp file to capture what would go to stdout.
function M._set_stream(s)
   stream = s or io.stdout
end

-- Encodes one body as a single JSON line (no trailing newline). Returns nil, err on failure.
function M.encode(body)
   local ok, line = pcall(json.encode, body, { keyorder = KEY_ORDER })
   if not ok or type(line) ~= "string" then
      return nil, "cannot encode output: " .. tostring(line)
   end
   return line
end

-- Writes one body as one line on stdout and flushes. Returns true, or nil, err when the body
-- cannot be encoded (nothing is written then) or stdout is gone.
function M.emit(body)
   local line, err = M.encode(body)
   if not line then
      return nil, err
   end
   local ok, werr = pcall(function()
      assert(stream:write(line, "\n"))
      assert(stream:flush())
   end)
   if not ok then
      return nil, "cannot write stdout: " .. tostring(werr)
   end
   return true
end

-- The minimal error body shared by all commands (ADR 0003).
function M.error_body(code, detail)
   return { ok = false, code = code, detail = detail }
end

return M
