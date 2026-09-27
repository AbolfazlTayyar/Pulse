-- cache.lua: bounded LRU (ADR 0014).
local cache = require("src.cache")
local json = require("src.vendor.dkjson")

local function item(symbol, as_of, pad)
   return { symbol = symbol, quote = "USD", price = "1" .. (pad or ""), volume_24h = "1", change_24h_pct = "0",
      as_of_unix = as_of or 1000, stale = false }
end

local function size(it) return #json.encode(it) end

describe("cache", function()
   it("evicts the least recently used entry", function()
      local c = cache.new(2, 1e6)
      c:put("A", item("A"))
      c:put("B", item("B"))
      assert.truthy(c:get("A", 1000, 5))
      c:put("C", item("C"))
      assert.is_nil(c:get("B", 1000, 5))
      assert.truthy(c:get("A", 1000, 5))
      assert.truthy(c:get("C", 1000, 5))
      assert.are.equal(1, c:stats().evictions)
   end)

   it("evicts by bytes", function()
      local s = size(item("A"))
      local c = cache.new(100, 2 * s + 1)
      c:put("A", item("A"))
      c:put("B", item("B"))
      c:put("C", item("C"))
      assert.are.same({ "C", "B" }, c:keys())
      assert.is_true(c:stats().bytes <= 2 * s + 1)
   end)

   it("does not store an entry larger than max_bytes", function()
      local c = cache.new(10, 1024 * 1024)
      c:put("small", item("S"))
      assert.is_false(c:put("big", item("B", 1000, string.rep("9", 2 * 1024 * 1024))))
      assert.is_nil(c:get("big", 1000, 5))
      assert.truthy(c:get("small", 1000, 5)) -- nothing was evicted for it
   end)

   it("serves an entry only while it is fresh", function()
      local c = cache.new(10, 1e6)
      c:put("A", item("A", 1000))
      assert.truthy(c:get("A", 1004, 5))
      assert.is_nil(c:get("A", 1005, 5))
      assert.is_nil(c:get("A", 1000, 5)) -- dropped once found too old
      assert.are.equal(0, c:stats().entries)
   end)

   it("replaces an existing key without double counting", function()
      local c = cache.new(10, 1e6)
      c:put("A", item("A"))
      c:put("A", item("A", 1001))
      local st = c:stats()
      assert.are.equal(1, st.entries)
      assert.are.equal(size(item("A", 1001)), st.bytes)
      assert.are.equal("1001", tostring(c:get("A", 1001, 5).as_of_unix))
   end)

   it("returns copies, so callers can't corrupt the cache", function()
      local c = cache.new(10, 1e6)
      local it = item("A")
      c:put("A", it)
      it.price = "999"
      local got = c:get("A", 1000, 5)
      got.price = "0"
      assert.are.equal("1", c:get("A", 1000, 5).price)
   end)

   it("counts hits and misses", function()
      local c = cache.new(10, 1e6)
      c:put("A", item("A"))
      c:get("A", 1000, 5)
      c:get("B", 1000, 5)
      local st = c:stats()
      assert.are.equal(1, st.hits)
      assert.are.equal(1, st.misses)
   end)

   it("never exceeds either limit under random load", function()
      math.randomseed(42)
      local max_entries, max_bytes = 17, 2500
      local c = cache.new(max_entries, max_bytes)
      for _ = 1, 20000 do
         local k = "K" .. math.random(1, 60)
         if math.random() < 0.6 then
            c:put(k, item(k, 1000 + math.random(0, 10), string.rep("0", math.random(0, 300))))
         else
            c:get(k, 1000 + math.random(0, 10), 5)
         end
         local st = c:stats()
         assert(st.entries <= max_entries, "entries " .. st.entries)
         assert(st.bytes <= max_bytes, "bytes " .. st.bytes)
         assert(#c:keys() == st.entries)
      end
   end)
end)
