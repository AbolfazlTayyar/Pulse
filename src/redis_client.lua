-- Minimal RESP2 client over luasocket (ADR 0013). Every operation has a timeout and respects
-- the invocation deadline; every failure is returned as nil, err (never raised). Retries follow
-- ADR 0021: at most one, after reconnecting, only when nothing was sent yet or the caller marked
-- the command idempotent, and only if the deadline still allows more than the Redis timeout.
-- Name lookup is the one step no timeout here can bound: luasocket calls a blocking
-- getaddrinfo(). A failed lookup is therefore never retried, and hosts should use an IP for
-- REDIS_HOST or cap the resolver (glibc: RES_OPTIONS="timeout:1 attempts:1", set in
-- docker-compose.yml).
local socket = require("socket")
local log = require("src.log")
local output = require("src.output")

local M = {}

-- Reply for a missing key (null bulk / null array). Distinct from a failure (nil, err).
M.null = setmetatable({}, { __tostring = function() return "redis.null" end })

local MAX_BULK = 64 * 1024 * 1024

local Client = {}
Client.__index = Client

local function now_ms()
   return socket.gettime() * 1000
end

-- ms for the next operation: the Redis timeout, cut short by the deadline.
function Client:_timeout_ms()
   local t = self.timeout_ms
   if self.deadline then
      t = math.min(t, self.deadline:remaining_ms())
   end
   return t
end

function Client:_may_retry()
   return self.deadline == nil or self.deadline:allows(self.timeout_ms)
end

function Client:_close()
   if self.sock then
      pcall(self.sock.close, self.sock)
      self.sock = nil
   end
end

function Client:close()
   self:_close()
end

local function encode(args)
   local parts = { "*" .. #args .. "\r\n" }
   for i = 1, #args do
      local a = args[i]
      if math.type(a) == "integer" then
         a = string.format("%d", a)
      elseif type(a) ~= "string" then
         return nil, "argument " .. i .. " must be a string or integer"
      end
      parts[#parts + 1] = "$" .. #a .. "\r\n" .. a .. "\r\n"
   end
   return table.concat(parts)
end

-- One reply. Returns value, or nil, err, kind ("io" | "reply" for a Redis error reply).
function Client:_read_reply(op_deadline)
   local sock = self.sock
   local function remaining_s()
      return math.max(0, op_deadline - now_ms()) / 1000
   end
   local function receive(pattern)
      sock:settimeout(remaining_s())
      local data, err = sock:receive(pattern)
      if not data then
         return nil, err
      end
      return data
   end

   local line, err = receive("*l")
   if not line then
      return nil, "read: " .. err, "io"
   end
   local prefix, rest = line:sub(1, 1), line:sub(2)
   if prefix == "+" then
      return rest
   elseif prefix == "-" then
      return nil, rest, "reply"
   elseif prefix == ":" then
      local n = math.tointeger(tonumber(rest))
      if not n then
         return nil, "protocol: bad integer", "io"
      end
      return n
   elseif prefix == "$" then
      local len = math.tointeger(tonumber(rest))
      if not len or len > MAX_BULK then
         return nil, "protocol: bad bulk length", "io"
      end
      if len < 0 then
         return M.null
      end
      local data
      data, err = receive(len + 2)
      if not data then
         return nil, "read: " .. err, "io"
      end
      return data:sub(1, len)
   elseif prefix == "*" then
      local n = math.tointeger(tonumber(rest))
      if not n then
         return nil, "protocol: bad array length", "io"
      end
      if n < 0 then
         return M.null
      end
      local arr = {}
      for i = 1, n do
         local v, e, kind = self:_read_reply(op_deadline)
         -- An error reply inside an array (e.g. from EVAL) is kept as a value.
         if v == nil and kind ~= "reply" then
            return nil, e, kind
         end
         arr[i] = v == nil and { err = e } or v
      end
      return arr
   end
   return nil, "protocol: unexpected reply type", "io"
end

-- Sends one command and reads its reply. kind: "unsent" (nothing reached the socket), "io"
-- (state unknown), "reply" (Redis answered with an error; the connection is still fine).
function Client:_exchange(args)
   local payload, err = encode(args)
   if not payload then
      return nil, err, "unsent"
   end
   local t = self:_timeout_ms()
   if t <= 0 then
      return nil, "deadline exceeded", "unsent"
   end
   local op_deadline = now_ms() + t
   self.sock:settimeout(t / 1000)
   local sent, serr, last = self.sock:send(payload)
   if not sent then
      return nil, "send: " .. serr, (last or 0) == 0 and "unsent" or "io"
   end
   return self:_read_reply(op_deadline)
end

function Client:_open()
   self:_close()
   local t = self:_timeout_ms()
   if t <= 0 then
      return nil, "deadline exceeded"
   end
   local sock = socket.tcp()
   sock:settimeout(t / 1000)
   local ok, err = sock:connect(self.host, self.port)
   if not ok then
      pcall(sock.close, sock)
      return nil, "connect " .. self.host .. ":" .. self.port .. ": " .. tostring(err)
   end
   pcall(sock.setoption, sock, "tcp-nodelay", true)
   self.sock = sock
   if self.password then
      local reply, aerr = self:_exchange({ "AUTH", self.password })
      if reply == nil then
         self:_close()
         -- The error text comes from Redis or the socket; it never contains the password.
         return nil, "auth failed: " .. tostring(aerr)
      end
   end
   return true
end

-- True for DNS failures: they take seconds and won't heal within one invocation.
local function is_name_resolution_error(err)
   err = tostring(err):lower()
   return err:find("name resolution", 1, true) ~= nil or err:find("host not found", 1, true) ~= nil
      or err:find("not known", 1, true) ~= nil
end

-- A connection failure happens before any command is sent, so one retry is safe, except
-- after a failed name lookup.
function Client:_open_with_retry()
   local ok, err = self:_open()
   if not ok and not is_name_resolution_error(err) and self:_may_retry() then
      ok, err = self:_open()
   end
   return ok, err
end

function Client:_call(idempotent, args)
   local op = type(args[1]) == "string" and args[1]:upper() or "?"
   local t0 = now_ms()
   local reply, err, kind
   if not self.sock then
      local ok, oerr = self:_open_with_retry()
      if not ok then
         reply, err = nil, oerr
      end
   end
   if self.sock then
      reply, err, kind = self:_exchange(args)
      if reply == nil and kind ~= "reply" then
         self:_close()
         if (kind == "unsent" or idempotent) and self:_may_retry() and self:_open() then
            reply, err, kind = self:_exchange(args)
            if reply == nil and kind ~= "reply" then
               self:_close()
            end
         end
      end
   end
   self.redis_ms = self.redis_ms + (now_ms() - t0)
   if reply == nil then
      log.error("redis_error", { op = op, detail = err })
      return nil, err, kind
   end
   return reply
end

-- Not retried after it may have reached Redis (INCR, SET NX, rate-limit EVAL, ...).
function Client:call(...)
   return self:_call(false, { ... })
end

-- Retried once after a reconnect: only for commands that are safe to repeat (GET, MGET, PING,
-- SET of a snapshot, compare-and-delete EVAL).
function Client:call_idempotent(...)
   return self:_call(true, { ... })
end

-- EVAL script numkeys keys... args...; opts.idempotent marks it safe to retry.
function Client:eval(script, keys, args, opts)
   local cmd = { "EVAL", script, #(keys or {}) }
   for _, k in ipairs(keys or {}) do cmd[#cmd + 1] = k end
   for _, a in ipairs(args or {}) do cmd[#cmd + 1] = a end
   return self:_call(opts and opts.idempotent or false, cmd)
end

-- Total ms spent talking to Redis (meta.redis_ms), rounded.
function Client:elapsed_ms()
   return math.floor(self.redis_ms + 0.5)
end

-- Connects (with at most one retry). deadline is optional. Returns client or nil, err.
function M.connect(host, port, timeout_ms, password, deadline)
   local self = setmetatable({
      host = host,
      port = port,
      timeout_ms = timeout_ms,
      password = password,
      deadline = deadline,
      redis_ms = 0,
   }, Client)
   local t0 = now_ms()
   local ok, err = self:_open_with_retry()
   self.redis_ms = now_ms() - t0
   if not ok then
      log.error("redis_error", { op = "CONNECT", detail = err })
      return nil, err
   end
   return self
end

function M.from_config(cfg, deadline)
   return M.connect(cfg.redis_host, cfg.redis_port, cfg.redis_timeout_ms, cfg.redis_password, deadline)
end

-- Client for one command: the daemon's shared client (ctx.redis, re-pointed at this request's
-- deadline) or a new connection. Returns client, redis_ms already spent on it; or nil, err.
function M.from_context(ctx)
   if ctx.redis then
      ctx.redis.deadline = ctx.deadline
      return ctx.redis, ctx.redis.redis_ms
   end
   local client, err = M.from_config(ctx.config, ctx.deadline)
   if not client then
      return nil, err
   end
   return client, 0
end

-- The one way every command reports a Redis failure (ADR 0009): body, exit code 3.
function M.unavailable(err)
   return output.error_body("REDIS_UNAVAILABLE", "redis unavailable: " .. tostring(err)), 3
end

return M
