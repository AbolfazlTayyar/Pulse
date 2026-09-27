-- `lua market.lua convert` for real, with prices seeded into the compose Redis (ADR 0020).
-- Expected strings were computed with Python 3.11 decimal (prec=200, quantize ROUND_HALF_EVEN).
local proc = require("tests.support.proc")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")

local SRC = "coingecko"
local SYMS = { "BTC", "USDT", "ETH", "DOGE" }

local function run(from, to, amount, env)
   return proc.run({ "convert", "--from", from, "--to", to, "--amount", amount }, env)
end

describe("convert command", function()
   local r, calls_before, now

   local function seed(symbol, price, age)
      assert(snapshot.write(r, SRC, { { symbol = symbol, quote = "USD", price = price, volume_24h = "1",
         change_24h_pct = "0", as_of_unix = now - (age or 0) } }, 3600))
   end

   before_each(function()
      r = assert(redis.connect(os.getenv("REDIS_HOST"), 6379, 500))
      for _, s in ipairs(SYMS) do r:call("DEL", snapshot.key(SRC, s)) end
      calls_before = snapshot.get_vendor_calls(r, SRC)
      now = os.time()
      seed("BTC", "67210.12", 0)
      seed("USDT", "1.00002813", 2)
   end)

   after_each(function()
      assert.are.equal(calls_before, snapshot.get_vendor_calls(r, SRC)) -- never calls the vendor
      for _, s in ipairs(SYMS) do r:call("DEL", snapshot.key(SRC, s)) end
      r:close()
   end)

   it("converts across two legs with one final half-even rounding (ADR 0020 example)", function()
      local res = run("BTC", "USDT", "1.5")
      assert.are.equal(0, res.code)
      local b = res.body
      assert.is_true(b.ok)
      assert.are.equal("convert.v1", b.schema)
      assert.are.equal("BTC", b.from)
      assert.are.equal("USDT", b.to)
      assert.are.equal("1.5", b.amount)
      assert.are.equal("100812.34414876", b.result)
      assert.are.equal("67208.22943251", b.rate)
      assert.is_false(b.stale)
      assert.are.equal(tostring(now - 2), b.as_of_unix) -- oldest leg
      assert.are.same({ symbol = "BTC", quote = "USD", price = "67210.12", as_of_unix = tostring(now), stale = false },
         b.legs[1])
      assert.are.equal("1.00002813", b.legs[2].price)
      assert.are.equal("hit", b.meta.cache)
      assert.are.equal("0", b.meta.http_ms)
      assert.truthy(res.out:find('"result":"100812.34414876"', 1, true)) -- a string, never a JSON number
   end)

   it("to the quote: amount x price", function()
      local b = run("BTC", "USD", "2").body
      assert.are.equal("134420.24000000", b.result)
      assert.are.equal("67210.12000000", b.rate)
      assert.are.equal(1, #b.legs)
   end)

   it("from the quote: amount / price", function()
      local b = run("USD", "USDT", "100").body
      assert.are.equal("99.99718708", b.result)
      assert.are.equal("0.99997187", b.rate)
   end)

   it("same symbol: rate 1, no legs", function()
      local res = run("BTC", "BTC", "1.5")
      assert.are.equal(0, res.code)
      assert.are.equal("1.50000000", res.body.result)
      assert.are.equal("1.00000000", res.body.rate)
      assert.truthy(res.out:find('"legs":[]', 1, true))
   end)

   it("handles 30 integer digits x 18 decimals without overflow", function()
      local b = run("BTC", "USDT", "123456789012345678901234567890.123456789012345678").body
      assert.are.equal("8297312200942222055727015855087340.73870935", b.result)
   end)

   it("honours CONVERT_SCALE", function()
      assert.are.equal("100812.34", run("BTC", "USDT", "1.5", proc.env({ CONVERT_SCALE = "2" })).body.result)
   end)

   it("missing price -> PRICE_UNAVAILABLE, exit 1", function()
      local res = run("DOGE", "USD", "1")
      assert.are.equal(1, res.code)
      assert.are.same({ ok = false, code = "PRICE_UNAVAILABLE", detail = "no cached price for DOGE" }, res.body)
   end)

   it("stale leg -> still converts, stale true, exit 0", function()
      seed("USDT", "1.00002813", 600)
      local res = run("BTC", "USDT", "1.5")
      assert.are.equal(0, res.code)
      assert.is_true(res.body.stale)
      assert.is_true(res.body.legs[2].stale)
      assert.are.equal("mixed", res.body.meta.cache)
      assert.are.equal("100812.34414876", res.body.result)
   end)

   it("Redis down -> REDIS_UNAVAILABLE, exit 3", function()
      assert.are.equal(3, run("BTC", "USDT", "1", proc.env({ REDIS_PORT = "1" })).code)
   end)
end)
