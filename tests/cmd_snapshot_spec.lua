-- `lua market.lua snapshot` for real, against the compose Redis seeded directly (ADR 0022).
local proc = require("tests.support.proc")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")

local SOURCE = "coingecko"
local SYMS = { "BTC", "ETH", "DOGE" }

local function item(symbol, as_of, price)
   return { symbol = symbol, quote = "USD", price = price or "67210.12", volume_24h = "12345.67",
      change_24h_pct = "-1.24", as_of_unix = as_of }
end

describe("snapshot command", function()
   local r, calls_before

   before_each(function()
      r = assert(redis.connect(os.getenv("REDIS_HOST"), 6379, 500))
      for _, s in ipairs(SYMS) do r:call("DEL", snapshot.key(SOURCE, s)) end
      calls_before = snapshot.get_vendor_calls(r, SOURCE)
   end)

   after_each(function()
      assert.are.equal(calls_before, snapshot.get_vendor_calls(r, SOURCE)) -- never calls the vendor
      for _, s in ipairs(SYMS) do r:call("DEL", snapshot.key(SOURCE, s)) end
      r:close()
   end)

   it("prints fresh items and a PRICE_UNAVAILABLE error for a missing symbol (partial, exit 0)", function()
      local as_of = os.time() - 2
      snapshot.write(r, SOURCE, { item("BTC", as_of, "84115.123456789012345") }, 3600)
      local res = proc.run({ "snapshot", "--symbols", "BTC,DOGE" })
      assert.are.equal(0, res.code)
      local b = res.body
      assert.is_true(b.ok)
      assert.are.equal("ticker.v1", b.schema)
      assert.are.equal("coingecko", b.source)
      assert.are.equal(1, #b.items)
      assert.are.equal("84115.123456789012345", b.items[1].price)
      assert.is_false(b.items[1].stale)
      assert.are.same({ { symbol = "DOGE", code = "PRICE_UNAVAILABLE", detail = "no cached price for DOGE" } }, b.errors)
      assert.are.equal("hit", b.meta.cache)
      assert.is_true(b.meta.partial)
      assert.are.equal("0", b.meta.http_ms)
      assert.is_string(b.meta.redis_ms)
      assert.are.equal(tostring(as_of), b.as_of_unix)
   end)

   it("serves old data as stale, still ok and exit 0", function()
      local old = os.time() - 1200
      snapshot.write(r, SOURCE, { item("BTC", old) }, 3600)
      snapshot.write(r, SOURCE, { item("ETH", os.time()) }, 3600)
      local res = proc.run({ "snapshot", "--symbols", "BTC,ETH" })
      assert.are.equal(0, res.code)
      assert.is_true(res.body.ok)
      assert.is_true(res.body.items[1].stale)
      assert.is_false(res.body.items[2].stale)
      assert.are.equal("mixed", res.body.meta.cache)
      assert.is_false(res.body.meta.partial)
      assert.are.equal(tostring(old), res.body.as_of_unix)
      assert.truthy(res.err:find('"event":"stale_served"', 1, true))
      snapshot.write(r, SOURCE, { item("ETH", os.time() - 1200) }, 3600)
      assert.are.equal("stale", proc.run({ "snapshot", "--symbols", "BTC,ETH" }).body.meta.cache)
   end)

   it("fails with PRICE_UNAVAILABLE and exit 1 when nothing is cached", function()
      local res = proc.run({ "snapshot", "--symbols", "BTC,DOGE" })
      assert.are.equal(1, res.code)
      assert.is_false(res.body.ok)
      assert.are.equal("PRICE_UNAVAILABLE", res.body.code)
      assert.are.equal(2, #res.body.errors)
      assert.are.same({}, res.body.items)
   end)

   it("fails closed with REDIS_UNAVAILABLE and exit 3 when Redis is unreachable", function()
      local res = proc.run({ "snapshot", "--symbols", "BTC" }, proc.env({ REDIS_PORT = "1" }))
      assert.are.equal(3, res.code)
      assert.are.equal("REDIS_UNAVAILABLE", res.body.code)
   end)
end)
