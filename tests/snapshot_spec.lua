-- snapshot.lua against the compose Redis, with an injected "now" (no sleeping).
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local lock = require("src.lock")
local log = require("src.log")

local HOST = os.getenv("REDIS_HOST") or "127.0.0.1"

local function item(symbol, as_of, price)
   return {
      symbol = symbol, quote = "USD", price = price or "67210.12", volume_24h = "12345.67",
      change_24h_pct = "-1.24", as_of_unix = as_of, stale = false,
   }
end

describe("snapshot", function()
   local r, source, logs

   before_each(function()
      r = assert(redis.connect(HOST, 6379, 200))
      source = "test-c4-" .. lock.new_token():sub(1, 8)
      logs = assert(io.tmpfile())
      log._set_stream(logs)
   end)

   after_each(function()
      local keys = r:call("KEYS", "mkt:*:" .. source .. "*")
      if type(keys) == "table" and #keys > 0 then r:call("DEL", table.unpack(keys)) end
      r:close()
      log._set_stream(nil)
   end)

   it("writes each item with a TTL and reads it back with per-item freshness", function()
      assert.is_true(snapshot.write(r, source, { item("BTC", 1000) }, 3600))
      local ttl = r:call("TTL", snapshot.key(source, "BTC"))
      assert.is_true(ttl > 3590 and ttl <= 3600, tostring(ttl))

      local fresh = snapshot.read(r, source, { "BTC" }, 1003, 5)
      assert.are.same(item("BTC", 1000), fresh.BTC)
      assert.is_false(fresh.BTC.stale)

      local old = snapshot.read(r, source, { "BTC" }, 1010, 5)
      assert.is_true(old.BTC.stale)
      assert.is_true(snapshot.read(r, source, { "BTC" }, 1005, 5).BTC.stale) -- exactly fresh_s old
   end)

   it("keeps decimal strings byte for byte", function()
      snapshot.write(r, source, { item("BTC", 1000, "84115.123456789012345") }, 60)
      assert.are.equal("84115.123456789012345", snapshot.read(r, source, { "BTC" }, 1000, 5).BTC.price)
   end)

   it("reports missing symbols with one MGET", function()
      snapshot.write(r, source, { item("BTC", 1000) }, 60)
      local res = snapshot.read(r, source, { "BTC", "DOGE" }, 1000, 5)
      assert.are.equal("BTC", res.BTC.symbol)
      assert.are.equal(snapshot.MISSING, res.DOGE)
   end)

   it("treats a corrupt stored value as missing and logs it", function()
      r:call("SET", snapshot.key(source, "ETH"), "garbage")
      r:call("SET", snapshot.key(source, "SOL"), '{"symbol":"SOL","quote":"USD","price":"abc"}')
      r:call("SET", snapshot.key(source, "ADA"), '{"symbol":"XRP","quote":"USD","price":"1","volume_24h":"1",'
         .. '"change_24h_pct":"1","as_of_unix":1000}')
      local res = snapshot.read(r, source, { "ETH", "SOL", "ADA" }, 1000, 5)
      assert.are.equal(snapshot.MISSING, res.ETH)
      assert.are.equal(snapshot.MISSING, res.SOL)
      assert.are.equal(snapshot.MISSING, res.ADA)
      logs:seek("set", 0)
      local out = logs:read("a")
      assert.truthy(out:find('"symbol":"ETH"', 1, true))
      assert.truthy(out:find("corrupt snapshot", 1, true))
   end)

   it("refuses to write an item that isn't a complete ticker", function()
      local bad = item("BTC", 1000)
      bad.price = nil
      local ok, err = snapshot.write(r, source, { item("ETH", 1000), bad }, 60)
      assert.is_nil(ok)
      assert.truthy(err:find("price", 1, true))
      assert.are.equal(redis.null, r:call("GET", snapshot.key(source, "ETH"))) -- nothing written
      local nonint = item("BTC", 1000.5)
      assert.is_nil(snapshot.write(r, source, { nonint }, 60))
   end)

   it("stores and reads last_fetch", function()
      assert.are.equal(false, snapshot.get_last_fetch(r, source))
      assert.is_true(snapshot.set_last_fetch(r, source, 1726900000))
      assert.are.equal(1726900000, snapshot.get_last_fetch(r, source))
   end)

   it("counts vendor calls without a TTL", function()
      assert.are.equal(0, snapshot.get_vendor_calls(r, source))
      assert.are.equal(1, snapshot.incr_vendor_calls(r, source))
      assert.are.equal(2, snapshot.incr_vendor_calls(r, source))
      assert.are.equal(2, snapshot.get_vendor_calls(r, source))
      assert.are.equal(-1, r:call("TTL", "mkt:stats:vendor_calls:" .. source))
   end)

   it("returns nil, err when Redis fails", function()
      r.port = 1
      r:close()
      local res, err = snapshot.read(r, source, { "BTC" }, 1000, 5)
      assert.is_nil(res)
      assert.is_string(err)
   end)

   describe("summarize", function()
      local function it_(as_of, stale) return { as_of_unix = as_of, stale = stale } end

      it("uses the oldest item's as_of_unix", function()
         assert.are.equal(990, (snapshot.summarize({ it_(1000, false), it_(990, false), it_(995, false) })))
      end)

      it("derives meta.cache: hit, stale or mixed", function()
         assert.are.equal("hit", select(2, snapshot.summarize({ it_(1000, false), it_(1001, false) })))
         assert.are.equal("stale", select(2, snapshot.summarize({ it_(1000, true), it_(1001, true) })))
         assert.are.equal("mixed", select(2, snapshot.summarize({ it_(1000, true), it_(1001, false) })))
      end)

      it("returns nil for no items", function()
         assert.are.same({}, { snapshot.summarize({}) })
      end)
   end)
end)
