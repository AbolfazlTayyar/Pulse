-- lock.lua against the compose Redis (ADR 0008).
local redis = require("src.redis_client")
local lock = require("src.lock")
local log = require("src.log")
local socket = require("socket")

local HOST = os.getenv("REDIS_HOST") or "127.0.0.1"

local function connect()
   return assert(redis.connect(HOST, 6379, 200))
end

describe("lock", function()
   local source, a, b

   before_each(function()
      source = "test-c2-" .. lock.new_token():sub(1, 8)
      a, b = connect(), connect()
      log._set_stream(assert(io.tmpfile()))
   end)

   after_each(function()
      a:call("DEL", lock.key(source))
      a:close()
      b:close()
      log._set_stream(nil)
   end)

   it("makes tokens unguessable and unique", function()
      local seen = {}
      for _ = 1, 1000 do
         local t = lock.new_token()
         assert.truthy(t:match("^%x+$"))
         assert.are.equal(32, #t)
         assert.is_nil(seen[t])
         seen[t] = true
      end
   end)

   it("lets exactly one of two clients hold the lock", function()
      local ta = lock.acquire(a, source, 3000)
      assert.is_string(ta)
      assert.are.equal(false, lock.acquire(b, source, 3000))
      assert.are.equal(ta, a:call("GET", "mkt:lock:" .. source))
   end)

   it("releases for the holder, after which the other can take it", function()
      local ta = lock.acquire(a, source, 3000)
      assert.is_true(lock.release(a, source, ta))
      assert.are.equal(redis.null, a:call("GET", lock.key(source)))
      assert.is_string(lock.acquire(b, source, 3000))
   end)

   it("a late release after expiry never deletes the new holder's lock", function()
      local ta = lock.acquire(a, source, 100)
      socket.sleep(0.15) -- A's lock expires
      local tb = lock.acquire(b, source, 3000)
      assert.is_string(tb)
      assert.are.equal(false, lock.release(a, source, ta)) -- lock_lost
      assert.are.equal(tb, b:call("GET", lock.key(source)))
      assert.is_true(lock.release(b, source, tb))
   end)

   it("expires without release when the holder is killed", function()
      local killed = connect()
      assert.is_string(lock.acquire(killed, source, 100))
      killed:close() -- never releases
      assert.are.equal(false, lock.acquire(a, source, 3000))
      socket.sleep(0.15)
      assert.are.equal(redis.null, a:call("GET", lock.key(source)))
      assert.is_string(lock.acquire(a, source, 3000))
   end)

   it("reports the remaining TTL, and 0 once the lock is gone", function()
      local ta = lock.acquire(a, source, 3000)
      local ms = lock.remaining_ttl_ms(a, source)
      assert.is_true(ms > 2800 and ms <= 3000, tostring(ms))
      lock.release(a, source, ta)
      assert.are.equal(0, lock.remaining_ttl_ms(a, source))
   end)

   it("returns nil, err on Redis failure", function()
      local c = connect()
      c.port = 1 -- next reconnect fails
      c:close()
      local tok, err = lock.acquire(c, source, 3000)
      assert.is_nil(tok)
      assert.is_string(err)
   end)
end)
