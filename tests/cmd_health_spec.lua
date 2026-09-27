-- `lua market.lua health` for real (ADR 0022).
local proc = require("tests.support.proc")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local limiter = require("src.limiter")

describe("health command", function()
   local r, saved

   before_each(function()
      r = assert(redis.connect(os.getenv("REDIS_HOST"), 6379, 500))
      saved = {
         last = r:call("GET", "mkt:meta:last_fetch:coingecko"),
         calls = r:call("GET", "mkt:stats:vendor_calls:coingecko"),
      }
      r:call("DEL", "mkt:meta:last_fetch:coingecko", limiter.cooldown_key("coingecko"))
   end)

   after_each(function()
      r:call("DEL", "mkt:meta:last_fetch:coingecko", limiter.cooldown_key("coingecko"))
      if saved.last ~= redis.null then r:call("SET", "mkt:meta:last_fetch:coingecko", saved.last) end
      r:close()
   end)

   it("is healthy with no fetch yet: real PING, null last fetch", function()
      local res = proc.run({ "health" })
      assert.are.equal(0, res.code)
      local b = res.body
      assert.is_true(b.ok)
      assert.are.equal("health.v1", b.schema)
      assert.are.same({ ok = true, lua = "Lua 5.4", version = "0.1.0" }, b.process)
      assert.is_true(b.redis.ok)
      assert.truthy(b.redis.latency_ms:match("^%d+$"))
      assert.are.equal("coingecko", b.source.name)
      assert.truthy(res.out:find('"last_fetch_unix":null', 1, true))
      assert.truthy(res.out:find('"last_fetch_age_s":null', 1, true))
      assert.is_false(b.source.cooldown_active)
      assert.are.equal(tostring(snapshot.get_vendor_calls(r, "coingecko")), b.source.vendor_calls)
   end)

   it("reports last fetch age and an active cooldown", function()
      local last = os.time() - 100
      snapshot.set_last_fetch(r, "coingecko", last)
      limiter.set_cooldown(r, "coingecko", "30")
      local b = proc.run({ "health" }).body
      assert.is_true(b.ok) -- the source block is informational
      assert.are.equal(tostring(last), b.source.last_fetch_unix)
      local age = tonumber(b.source.last_fetch_age_s)
      assert.is_true(age >= 100 and age <= 102)
      assert.is_true(b.source.cooldown_active)
   end)

   it("prints the full body and exits 3 when Redis is unreachable", function()
      local res = proc.run({ "health" }, proc.env({ REDIS_PORT = "1" }))
      assert.are.equal(3, res.code)
      local b = res.body
      assert.is_false(b.ok)
      assert.are.equal("health.v1", b.schema)
      assert.is_true(b.process.ok)
      assert.is_false(b.redis.ok)
      assert.truthy(b.redis.error:find("refused", 1, true))
      assert.truthy(res.out:find('"vendor_calls":null', 1, true))
      assert.truthy(res.out:find('"cooldown_active":null', 1, true))
   end)
end)
