-- JSON-lines logger on stderr (ADR 0019). Never writes stdout, never logs secrets, and a failed
-- write never fails the job.
local json = require("src.vendor.dkjson")

local M = {}

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }
local KEY_ORDER = { "ts", "level", "inv", "req", "event" }
local RESERVED = { ts = true, level = true, inv = true, req = true, event = true }

-- Field names whose values are never written, at any nesting depth.
local SECRET_KEYS = {
   "password", "passwd", "pass", "secret", "auth", "authorization", "credential", "credentials",
   "api_key", "apikey",
}
local REDACTED = "[redacted]"

local ok_socket, socket = pcall(require, "socket")

local function now_s()
   if ok_socket then
      return socket.gettime()
   end
   return os.time()
end

-- 8 hex chars from the kernel RNG; many processes start in the same millisecond, so a
-- time-seeded math.random would collide.
local function random_hex8()
   local f = io.open("/dev/urandom", "rb")
   if f then
      local bytes = f:read(4)
      f:close()
      if bytes and #bytes == 4 then
         return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
      end
   end
   return string.format("%08x", math.random(0, 0x7fffffff))
end

local stream = io.stderr
local threshold = LEVELS[os.getenv("LOG_LEVEL") or ""] or LEVELS.info
local inv = random_hex8()
local req = nil

function M.invocation_id()
   return inv
end

-- level: "debug" | "info" | "warn" | "error"; unknown values are ignored.
function M.set_level(level)
   if LEVELS[level] then
      threshold = LEVELS[level]
   end
end

-- Daemon mode: the current request id, or nil to clear it.
function M.set_request(id)
   req = id
end

-- Tests swap in a temp file to capture stderr.
function M._set_stream(s)
   stream = s or io.stderr
end

local function is_secret_key(k)
   if type(k) ~= "string" then
      return false
   end
   local lower = k:lower()
   for _, s in ipairs(SECRET_KEYS) do
      if lower == s or lower:find(s, 1, true) then
         return true
      end
   end
   return false
end

-- Copy of v with secret-named fields redacted; cycles and depth are bounded.
local function scrub(v, depth)
   if type(v) ~= "table" then
      if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then
         return tostring(v)
      end
      return v
   end
   if depth > 6 then
      return "[truncated]"
   end
   local out = {}
   for k, val in pairs(v) do
      out[k] = is_secret_key(k) and REDACTED or scrub(val, depth + 1)
   end
   return setmetatable(out, getmetatable(v))
end

local function iso8601_utc(t)
   local sec = math.floor(t)
   local ms = math.floor((t - sec) * 1000)
   return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms)
end

-- Last line of defence: the configured Redis password never appears in a log line, even inside
-- a free-text detail.
local function strip_env_secret(line)
   local pw = os.getenv("REDIS_PASSWORD")
   if pw and #pw > 0 then
      local escaped = pw:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
      line = line:gsub(escaped, REDACTED)
   end
   return line
end

local function write(level, event, fields)
   if LEVELS[level] < threshold then
      return
   end
   pcall(function()
      local rec = {}
      if type(fields) == "table" then
         for k, v in pairs(fields) do
            if not RESERVED[k] then
               rec[k] = is_secret_key(k) and REDACTED or scrub(v, 1)
            end
         end
      end
      rec.ts = iso8601_utc(now_s())
      rec.level = level
      rec.inv = inv
      rec.req = req
      rec.event = tostring(event)
      local line = json.encode(rec, { keyorder = KEY_ORDER })
      stream:write(strip_env_secret(line), "\n")
      stream:flush()
   end)
end

function M.debug(event, fields) write("debug", event, fields) end
function M.info(event, fields) write("info", event, fields) end
function M.warn(event, fields) write("warn", event, fields) end
function M.error(event, fields) write("error", event, fields) end

return M
