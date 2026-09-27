-- `lua market.lua fetch` for real against the compose Redis. The vendor side is served from
-- tests/fixtures/ by tests/support/fixture_http.lua (SOURCE_URL=http://fixture/<file>), except
-- the timeout and connect-error cases, which use real sockets.
local proc = require("tests.support.proc")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local limiter = require("src.limiter")
local lock = require("src.lock")

local SRC = "coingecko"
local FIXTURE = "http://fixture/coingecko/simple_price.json"

local r

local function clear(source)
   source = source or SRC
   local keys = r:call("KEYS", "mkt:*" .. source .. "*")
   for _, k in ipairs(keys) do
      if not k:find("^mkt:stats:") then r:call("DEL", k) end
   end
end

local function calls(source)
   return snapshot.get_vendor_calls(r, source or SRC)
end

local function seed(symbol, age_s, price)
   assert(snapshot.write(r, SRC, { {
      symbol = symbol, quote = "USD", price = price or "60000.5", volume_24h = "1", change_24h_pct = "0",
      as_of_unix = os.time() - age_s,
   } }, 3600))
end

local function stored(symbol)
   return r:call("GET", snapshot.key(SRC, symbol))
end

-- fetch through the fixture hook; extra env on top of a generous rate limit.
local function fetch(symbols, extra)
   local env = { SOURCE_URL = FIXTURE, RATE_LIMIT_PER_WINDOW = "1000" }
   for k, v in pairs(extra or {}) do env[k] = v end
   return proc.run({ "fetch", symbols }, proc.env(env), { fixture = true })
end

describe("fetch command", function()
   before_each(function()
      r = assert(redis.connect(os.getenv("REDIS_HOST"), 6379, 500))
      clear()
   end)
   after_each(function()
      clear()
      clear("kraken")
      r:close()
   end)

   describe("cache hit and leader path (E3)", function()
      it("misses once, then hits with no vendor call", function()
         local before = calls()
         local first = fetch("BTC,ETH")
         assert.are.equal(0, first.code)
         assert.is_true(first.body.ok)
         assert.are.equal("miss", first.body.meta.cache)
         assert.are.equal("84115.123456789012345", first.body.items[1].price)
         assert.are.equal("ETH", first.body.items[2].symbol)
         assert.are.equal(before + 1, calls())
         assert.are.equal(redis.null, r:call("GET", lock.key(SRC))) -- lock released
         assert.truthy(r:call("GET", "mkt:meta:last_fetch:" .. SRC):match("^%d+$"))
         local ttl = r:call("TTL", snapshot.key(SRC, "BTC"))
         assert.is_true(ttl > 3590)

         local second = fetch("BTC,ETH")
         assert.are.equal(0, second.code)
         assert.are.equal("hit", second.body.meta.cache)
         assert.are.equal("0", second.body.meta.http_ms)
         assert.are.equal(first.body.items[1].price, second.body.items[1].price)
         assert.are.equal(before + 1, calls())
      end)

      it("treats unknown symbols as partial success", function()
         local res = fetch("BTC,FAKECOIN")
         assert.are.equal(0, res.code)
         assert.is_true(res.body.meta.partial)
         assert.are.same({ { symbol = "FAKECOIN", code = "UNKNOWN_SYMBOL", detail = "not supported by coingecko" } },
            res.body.errors)
         -- mapped but missing from the vendor's answer
         res = fetch("BTC,DOGE")
         assert.are.equal(0, res.code)
         assert.are.equal("DOGE", res.body.errors[1].symbol)
         assert.are.equal("UNKNOWN_SYMBOL", res.body.errors[1].code)
      end)

      it("answers only-unknown symbols with exit 1 and no vendor call", function()
         local before = calls()
         local res = fetch("FAKECOIN")
         assert.are.equal(1, res.code)
         assert.are.equal("UNKNOWN_SYMBOL", res.body.code)
         assert.are.equal(before, calls())
      end)

      it("reports bad vendor rows as BAD_PAYLOAD and never caches them", function()
         local res = fetch("BTC,ETH", { SOURCE_URL = "http://fixture/coingecko/missing_field.json" })
         assert.are.equal(1, res.code)
         assert.are.equal("BAD_PAYLOAD", res.body.code)
         assert.are.equal(2, #res.body.errors)
         assert.are.equal(redis.null, stored("BTC"))
         assert.are.equal(redis.null, stored("ETH"))
      end)

      it("retries a 5xx once and counts both attempts", function()
         local before = calls()
         local res = fetch("BTC", { FIXTURE_STATUS = "500,200" })
         assert.are.equal(0, res.code)
         assert.are.equal("miss", res.body.meta.cache)
         assert.are.equal(before + 2, calls())
      end)

      it("prints the same ticker.v1 shape for kraken (D3 checkpoint)", function()
         local res = fetch("BTC", { MARKET_SOURCE = "kraken", SOURCE_URL = "http://fixture/kraken/ticker.json" })
         assert.are.equal(0, res.code)
         assert.are.equal("kraken", res.body.source)
         assert.are.same({
            symbol = "BTC", quote = "USD", price = "67210.12000", volume_24h = "12345.67",
            change_24h_pct = "-1.24", as_of_unix = res.body.items[1].as_of_unix, stale = false,
         }, res.body.items[1])
      end)
   end)

   describe("followers and coalescing (E4)", function()
      it("20 parallel fetches make exactly one vendor call", function()
         local before = calls()
         local results = proc.run_parallel(20, { "fetch", "BTC,ETH" },
            proc.env({ SOURCE_URL = FIXTURE, FIXTURE_DELAY_MS = "300", RATE_LIMIT_PER_WINDOW = "1000" }),
            { fixture = true })
         local count = {}
         for _, res in ipairs(results) do
            assert.are.equal(0, res.code, res.out)
            local c = res.body.meta.cache
            count[c] = (count[c] or 0) + 1
         end
         assert.are.equal(before + 1, calls())
         assert.are.equal(1, count.miss)
         assert.are.equal(19, (count.coalesced or 0) + (count.hit or 0))
      end)

      it("a stuck leader ends in DEADLINE_EXCEEDED before the deadline, with last-good attached", function()
         seed("BTC", 600)
         r:call("SET", lock.key(SRC), "someone-else", "PX", 10000)
         local before = calls()
         local res = fetch("BTC,ETH", { DEADLINE_MS = "1500", LOCK_TTL_MS = "1000", SOURCE_TIMEOUT_MS = "500" })
         assert.are.equal(1, res.code)
         assert.are.equal("DEADLINE_EXCEEDED", res.body.code)
         assert.is_true(res.ms < 1500 + 300, "took " .. res.ms .. " ms") -- + process start-up
         assert.are.equal("BTC", res.body.items[1].symbol)
         assert.is_true(res.body.items[1].stale)
         assert.are.equal("ETH", res.body.errors[1].symbol)
         assert.are.equal(before, calls())
         assert.are.equal("someone-else", r:call("GET", lock.key(SRC)))
         assert.truthy(res.err:find('"event":"deadline_exceeded"', 1, true))
         assert.truthy(res.err:find('"event":"lock_busy"', 1, true))
      end)

      it("becomes leader when the lock disappears while data is still stale", function()
         r:call("SET", lock.key(SRC), "someone-else", "PX", 300)
         local res = fetch("BTC")
         assert.are.equal(0, res.code)
         assert.are.equal("miss", res.body.meta.cache)
      end)
   end)

   describe("vendor failures (E5)", function()
      local function assert_failure(res, code, before_calls, expected_calls)
         assert.are.equal(1, res.code)
         assert.is_false(res.body.ok)
         assert.are.equal(code, res.body.code)
         assert.are.equal("ticker.v1", res.body.schema)
         assert.are.equal("BTC", res.body.items[1].symbol) -- last-good attached
         assert.is_true(res.body.items[1].stale)
         assert.are.equal("60000.5", res.body.items[1].price)
         assert.are.equal("ETH", res.body.errors[1].symbol) -- no data at all
         assert.are.equal(before_calls + expected_calls, calls())
         assert.truthy(stored("BTC"):find('"60000.5"', 1, true)) -- last-good untouched
         assert.are.equal(redis.null, r:call("GET", lock.key(SRC)))
         assert.truthy(res.err:find('"event":"stale_served"', 1, true))
      end

      before_each(function() seed("BTC", 600) end)

      it("5xx twice -> SOURCE_UNAVAILABLE after one retry", function()
         local before = calls()
         local res = fetch("BTC,ETH", { FIXTURE_STATUS = "500" })
         assert_failure(res, "SOURCE_UNAVAILABLE", before, 2)
         assert.are.equal("coingecko: HTTP 500", res.body.detail)
      end)

      it("timeout -> SOURCE_UNAVAILABLE, never retried", function()
         local before = calls()
         assert_failure(fetch("BTC,ETH", { FIXTURE_STATUS = "timeout" }), "SOURCE_UNAVAILABLE", before, 1)
      end)

      it("real timeout against an unroutable address", function()
         local before = calls()
         local res = fetch("BTC,ETH", { SOURCE_URL = "http://10.255.255.1", SOURCE_TIMEOUT_MS = "500" })
         assert_failure(res, "SOURCE_UNAVAILABLE", before, 1)
         assert.truthy(res.body.detail:find("timeout", 1, true))
      end)

      it("real connect error on a closed port is retried once", function()
         local before = calls()
         assert_failure(fetch("BTC,ETH", { SOURCE_URL = "http://127.0.0.1:1" }), "SOURCE_UNAVAILABLE", before, 2)
      end)

      it("429 sets the cooldown; during it no process calls the vendor", function()
         local before = calls()
         local res = fetch("BTC,ETH", { FIXTURE_STATUS = "429", FIXTURE_RETRY_AFTER = "12",
            SOURCE_URL = "http://fixture/coingecko/rate_limited_429.json" })
         assert_failure(res, "RATE_LIMITED", before, 1)
         local ttl = r:call("TTL", limiter.cooldown_key(SRC))
         assert.is_true(ttl > 10 and ttl <= 12, tostring(ttl))
         assert.truthy(res.err:find('"event":"cooldown_set"', 1, true))

         local again = fetch("BTC,ETH")
         assert_failure(again, "RATE_LIMITED", before, 1) -- counter did not move
         assert.truthy(again.err:find('"event":"cooldown_active"', 1, true))
      end)

      it("an exhausted shared rate limit -> RATE_LIMITED without an HTTP call", function()
         local before = calls()
         assert.are.equal(0, fetch("ETH", { RATE_LIMIT_PER_WINDOW = "1" }).code)
         r:call("DEL", snapshot.key(SRC, "ETH"))
         local res = fetch("BTC,ETH", { RATE_LIMIT_PER_WINDOW = "1" })
         assert_failure(res, "RATE_LIMITED", before, 1)
         assert.truthy(res.err:find('"event":"rate_limited"', 1, true))
      end)

      it("undecodable payload -> BAD_PAYLOAD, last-good untouched", function()
         local before = calls()
         assert_failure(fetch("BTC,ETH", { SOURCE_URL = "http://fixture/coingecko/html_error.html" }),
            "BAD_PAYLOAD", before, 1)
      end)
   end)
end)
