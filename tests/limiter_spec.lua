-- limiter.lua against the compose Redis (ADR 0012, ADR 0011). "now" is injected, so windows
-- change without waiting.
local redis = require("src.redis_client")
local limiter = require("src.limiter")
local lock = require("src.lock")
local log = require("src.log")

local HOST = os.getenv("REDIS_HOST") or "127.0.0.1"

describe("limiter", function()
   local r, source, logs

   before_each(function()
      r = assert(redis.connect(HOST, 6379, 200))
      source = "test-c3-" .. lock.new_token():sub(1, 8)
      logs = assert(io.tmpfile())
      log._set_stream(logs)
   end)

   after_each(function()
      local keys = r:call("KEYS", "mkt:*:" .. source .. "*")
      if type(keys) == "table" and #keys > 0 then r:call("DEL", table.unpack(keys)) end
      r:call("DEL", limiter.cooldown_key(source))
      r:close()
      log._set_stream(nil)
   end)

   local function logged()
      logs:seek("set", 0)
      return logs:read("a")
   end

   describe("take", function()
      it("allows up to the limit, then refuses and logs rate_limited", function()
         for i = 1, 5 do
            local ok, n = limiter.take(r, source, 10, 5, 1000)
            assert.is_true(ok)
            assert.are.equal(i, n)
         end
         local ok, n = limiter.take(r, source, 10, 5, 1005)
         assert.is_false(ok)
         assert.are.equal(6, n)
         assert.truthy(logged():find('"event":"rate_limited"', 1, true))
         assert.truthy(logged():find('"limit":5', 1, true))
      end)

      it("starts over in the next window", function()
         for _ = 1, 6 do limiter.take(r, source, 10, 5, 1000) end
         local ok, n = limiter.take(r, source, 10, 5, 1010)
         assert.is_true(ok)
         assert.are.equal(1, n)
      end)

      it("gives every window key a TTL", function()
         limiter.take(r, source, 10, 5, 1000)
         local ttl = r:call("TTL", limiter.window_key(source, 10, 1000))
         assert.is_true(ttl > 0 and ttl <= 10, tostring(ttl))
      end)

      it("uses mkt:rl:{source}:{floor(now / window)}", function()
         assert.are.equal("mkt:rl:coingecko:172690000", limiter.window_key("coingecko", 10, 1726900009))
      end)

      it("returns nil, err on Redis failure", function()
         r.port = 1
         r:close()
         local ok, err = limiter.take(r, source, 10, 5, 1000)
         assert.is_nil(ok)
         assert.is_string(err)
      end)
   end)

   describe("cooldown", function()
      it("is inactive by default", function()
         assert.are.same({ false, 0 }, { limiter.cooldown_active(r, source) })
      end)

      it("uses Retry-After seconds as the TTL", function()
         assert.are.equal(12, limiter.set_cooldown(r, source, "12"))
         local active, ttl = limiter.cooldown_active(r, source)
         assert.is_true(active)
         assert.is_true(ttl > 10 and ttl <= 12)
         local out = logged()
         assert.truthy(out:find('"event":"cooldown_set"', 1, true))
         assert.truthy(out:find('"event":"cooldown_active"', 1, true))
      end)

      it("defaults to 30 s without a usable Retry-After", function()
         assert.are.equal(30, limiter.set_cooldown(r, source, nil))
         local _, ttl = limiter.cooldown_active(r, source)
         assert.is_true(ttl > 28 and ttl <= 30)
         for _, h in ipairs({ "", "abc", "-5", "1.5", "Wed, 21 Oct 2026 07:28:00 GMT", "9999999999" }) do
            assert.are.equal(30, limiter.cooldown_seconds(h), h)
         end
      end)

      it("clamps Retry-After to 1..3600 s", function()
         assert.are.equal(1, limiter.cooldown_seconds("0"))
         assert.are.equal(3600, limiter.cooldown_seconds("86400"))
         assert.are.equal(12, limiter.cooldown_seconds(" 12 "))
      end)
   end)
end)
