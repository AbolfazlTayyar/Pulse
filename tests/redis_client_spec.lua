-- redis_client.lua against the compose Redis (REDIS_HOST, set by docker-compose.yml).
local redis = require("src.redis_client")
local deadline = require("src.deadline")
local log = require("src.log")
local socket = require("socket")

local HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local PORT = 6379
local TIMEOUT = 200

local prefix = "test:c1:" .. string.format("%08x", math.random(0, 0x7fffffff)) .. ":"

local function connect(d)
   return assert(redis.connect(HOST, PORT, TIMEOUT, nil, d))
end

local function capture_log()
   local f = assert(io.tmpfile())
   log._set_stream(f)
   return function()
      log._set_stream(nil)
      f:seek("set", 0)
      local s = f:read("a")
      f:close()
      return s
   end
end

describe("redis_client", function()
   local r
   before_each(function() r = connect() end)
   after_each(function()
      local keys = r:call("KEYS", prefix .. "*")
      if type(keys) == "table" and #keys > 0 then r:call("DEL", table.unpack(keys)) end
      r:close()
   end)

   it("PING", function()
      assert.are.equal("PONG", r:call("PING"))
   end)

   it("SET / GET, including binary-safe values", function()
      assert.are.equal("OK", r:call("SET", prefix .. "k", "v"))
      assert.are.equal("v", r:call("GET", prefix .. "k"))
      local tricky = "a\r\nb\0c" .. string.rep("x", 5000)
      r:call("SET", prefix .. "t", tricky)
      assert.are.equal(tricky, r:call("GET", prefix .. "t"))
      r:call("SET", prefix .. "e", "")
      assert.are.equal("", r:call("GET", prefix .. "e"))
   end)

   it("returns redis.null for a missing key, not an error", function()
      local v, err = r:call("GET", prefix .. "missing")
      assert.are.equal(redis.null, v)
      assert.is_nil(err)
   end)

   it("reads arrays with null entries (MGET)", function()
      r:call("SET", prefix .. "a", "1")
      local v = r:call("MGET", prefix .. "a", prefix .. "nope")
      assert.are.same({ "1", redis.null }, v)
   end)

   it("INCR returns an integer", function()
      assert.are.equal(1, r:call("INCR", prefix .. "n"))
      assert.are.equal(2, r:call("INCR", prefix .. "n"))
      assert.are.equal("integer", math.type(r:call("INCR", prefix .. "n")))
   end)

   it("EVAL with keys and args", function()
      local v = r:eval("return {KEYS[1], ARGV[1], tonumber(ARGV[2]) + 1}", { prefix .. "k" }, { "hello", 41 })
      assert.are.same({ prefix .. "k", "hello", 42 }, v)
   end)

   it("returns an error reply as nil, err and keeps the connection usable", function()
      r:call("SET", prefix .. "s", "x")
      local restore = capture_log()
      local v, err, kind = r:call("INCR", prefix .. "s")
      local logged = restore()
      assert.is_nil(v)
      assert.truthy(err:find("ERR", 1, true))
      assert.are.equal("reply", kind)
      assert.truthy(logged:find('"event":"redis_error"', 1, true))
      assert.truthy(logged:find('"op":"INCR"', 1, true))
      assert.are.equal("PONG", r:call("PING"))
   end)

   it("rejects arguments that are not strings or integers without sending anything", function()
      local v, err = r:call("SET", prefix .. "k", 1.5)
      assert.is_nil(v)
      assert.truthy(err:find("must be a string or integer", 1, true))
      assert.are.equal("PONG", r:call("PING"))
   end)

   it("tracks time spent in Redis", function()
      local before = r.redis_ms
      r:call("PING")
      assert.is_true(r.redis_ms > before)
      assert.are.equal("integer", math.type(r:elapsed_ms()))
   end)

   describe("retries (ADR 0021)", function()
      local function kill(client)
         local id = client:call("CLIENT", "ID")
         local admin = connect()
         admin:call("CLIENT", "KILL", "ID", string.format("%d", id))
         admin:close()
      end

      it("retries an idempotent command once after the connection dropped", function()
         r:call("SET", prefix .. "k", "v")
         kill(r)
         assert.are.equal("v", r:call_idempotent("GET", prefix .. "k"))
      end)

      it("never retries INCR once it may have been sent", function()
         kill(r)
         local v, err = r:call("INCR", prefix .. "n")
         assert.is_nil(v)
         assert.is_string(err)
         local check = connect()
         assert.are.equal(redis.null, check:call("GET", prefix .. "n"))
         check:close()
         -- the next call reconnects
         assert.are.equal("PONG", r:call("PING"))
      end)

      it("does not retry when the deadline doesn't allow another Redis timeout", function()
         local now = 0
         local d = deadline.new(1000, { clock = function() return now end })
         local c = connect(d)
         c:call("SET", prefix .. "k", "v")
         kill(c)
         now = 850 -- 150 ms left < 200 ms Redis timeout
         local v = c:call_idempotent("GET", prefix .. "k")
         assert.is_nil(v)
         c:close()
      end)
   end)
end)

describe("redis_client failures", function()
   it("fails fast with connection refused (Redis stopped)", function()
      local t0 = socket.gettime()
      local c, err = redis.connect(HOST, 1, TIMEOUT)
      local ms = (socket.gettime() - t0) * 1000
      assert.is_nil(c)
      assert.truthy(err:find("refused", 1, true), err)
      assert.is_true(ms < TIMEOUT, "took " .. ms .. " ms")
   end)

   it("times out against an unroutable address within the Redis timeout (plus one retry)", function()
      local t0 = socket.gettime()
      local c, err = redis.connect("10.255.255.1", 6379, TIMEOUT)
      local ms = (socket.gettime() - t0) * 1000
      assert.is_nil(c)
      assert.is_string(err)
      assert.is_true(ms < 2 * TIMEOUT + 100, "took " .. ms .. " ms")
   end)

   it("does not retry the connect when the deadline is short", function()
      local d = deadline.new(250)
      local t0 = socket.gettime()
      local c = redis.connect("10.255.255.1", 6379, TIMEOUT, nil, d)
      local ms = (socket.gettime() - t0) * 1000
      assert.is_nil(c)
      assert.is_true(ms < TIMEOUT + 100, "took " .. ms .. " ms")
   end)

   it("does no I/O once the deadline has expired", function()
      local d = deadline.new(0)
      local c, err = redis.connect(HOST, PORT, TIMEOUT, nil, d)
      assert.is_nil(c)
      assert.are.equal("deadline exceeded", err:match("deadline exceeded"))
   end)

   it("reports a failed AUTH without logging the password", function()
      local restore = capture_log()
      local c, err = redis.connect(HOST, PORT, TIMEOUT, "hunter2-pw")
      local logged = restore()
      assert.is_nil(c) -- the compose Redis has no password configured
      assert.truthy(err:find("auth failed", 1, true))
      assert.is_nil(err:find("hunter2-pw", 1, true))
      assert.is_nil(logged:find("hunter2-pw", 1, true))
   end)

   it("builds the REDIS_UNAVAILABLE body with exit 3", function()
      local body, code = redis.unavailable("connect refused")
      assert.are.equal(3, code)
      assert.are.same({ ok = false, code = "REDIS_UNAVAILABLE", detail = "redis unavailable: connect refused" }, body)
   end)
end)
