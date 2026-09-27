-- config.lua: env validated once at startup (ADR 0017, ADR 0021).
local config = require("src.config")

local function fake_env(t)
   return function(k) return t[k] end
end

local function with(extra)
   local t = { REDIS_HOST = "redis" }
   for k, v in pairs(extra or {}) do t[k] = v end
   return fake_env(t)
end

local function expect_bad(env, fragment)
   local c, code, detail = config.load(env)
   assert.is_nil(c)
   assert.are.equal("BAD_CONFIG", code)
   assert.is_string(detail)
   assert.truthy(detail:find(fragment, 1, true), "detail was: " .. detail)
   return detail
end

describe("config", function()
   it("requires REDIS_HOST (unset or empty)", function()
      assert.are.equal("REDIS_HOST is required", expect_bad(fake_env({}), "REDIS_HOST"))
      expect_bad(fake_env({ REDIS_HOST = "" }), "REDIS_HOST is required")
      expect_bad(fake_env({ REDIS_HOST = "redis host" }), "REDIS_HOST")
   end)

   it("applies the documented defaults when only REDIS_HOST is set", function()
      local c = assert(config.load(with()))
      assert.are.equal("redis", c.redis_host)
      assert.are.equal(6379, c.redis_port)
      assert.is_nil(c.redis_password)
      assert.are.equal(200, c.redis_timeout_ms)
      assert.are.equal(2000, c.source_timeout_ms)
      assert.is_nil(c.source_url)
      assert.are.equal("coingecko", c.market_source)
      assert.are.equal("USD", c.market_quote)
      assert.are.equal(4000, c.deadline_ms)
      assert.are.equal(5, c.snapshot_fresh_s)
      assert.are.equal(3600, c.snapshot_keep_s)
      assert.are.equal(3000, c.lock_ttl_ms)
      assert.are.equal(10, c.rate_limit_window_s)
      assert.are.equal(5, c.rate_limit_per_window)
      assert.are.equal(1, c.max_concurrent_upstream)
      assert.are.equal(256, c.cache_max_entries)
      assert.are.equal(1048576, c.cache_max_bytes)
      assert.are.equal(8, c.convert_scale)
      assert.are.equal("info", c.log_level)
   end)

   it("reads overrides as integers", function()
      local c = assert(config.load(with({ REDIS_PORT = "6380", DEADLINE_MS = "4500", CONVERT_SCALE = "2" })))
      assert.are.equal(6380, c.redis_port)
      assert.are.equal("integer", math.type(c.deadline_ms))
      assert.are.equal(2, c.convert_scale)
   end)

   it("is immutable", function()
      local c = assert(config.load(with()))
      assert.has_error(function() c.redis_host = "evil" end)
      assert.are.equal("redis", c.redis_host)
   end)

   it("rejects non-positive-integer numeric values, naming the variable", function()
      local names = {
         "REDIS_PORT", "REDIS_TIMEOUT_MS", "SOURCE_TIMEOUT_MS", "DEADLINE_MS", "SNAPSHOT_FRESH_S",
         "SNAPSHOT_KEEP_S", "LOCK_TTL_MS", "RATE_LIMIT_WINDOW_S", "RATE_LIMIT_PER_WINDOW",
         "MAX_CONCURRENT_UPSTREAM", "CACHE_MAX_ENTRIES", "CACHE_MAX_BYTES", "CONVERT_SCALE",
      }
      for _, name in ipairs(names) do
         for _, v in ipairs({ "0", "-5", "1.5", "abc", "1e3", " 10", "0x10", "99999999999" }) do
            expect_bad(with({ [name] = v }), name)
         end
      end
   end)

   it("rejects a port above 65535", function()
      expect_bad(with({ REDIS_PORT = "70000" }), "REDIS_PORT")
   end)

   it("enforces SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS", function()
      local msg = "need SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS"
      expect_bad(with({ LOCK_TTL_MS = "1000" }), msg)
      expect_bad(with({ LOCK_TTL_MS = "2000" }), msg)
      expect_bad(with({ DEADLINE_MS = "3000" }), msg)
      expect_bad(with({ SOURCE_TIMEOUT_MS = "5000" }), msg)
      assert.truthy(config.load(with({ SOURCE_TIMEOUT_MS = "100", LOCK_TTL_MS = "200", DEADLINE_MS = "300" })))
   end)

   it("rejects a fresh window longer than the keep window", function()
      expect_bad(with({ SNAPSHOT_FRESH_S = "7200" }), "SNAPSHOT_FRESH_S")
   end)

   it("accepts only MAX_CONCURRENT_UPSTREAM=1 and points to ADR 0018", function()
      assert.truthy(config.load(with({ MAX_CONCURRENT_UPSTREAM = "1" })))
      local d = expect_bad(with({ MAX_CONCURRENT_UPSTREAM = "4" }), "only 1 is supported")
      assert.truthy(d:find("ADR 0018", 1, true))
   end)

   it("validates MARKET_SOURCE", function()
      for _, s in ipairs({ "coingecko", "binance", "kraken" }) do
         assert.are.equal(s, config.load(with({ MARKET_SOURCE = s })).market_source)
      end
      expect_bad(with({ MARKET_SOURCE = "coinbase" }), "MARKET_SOURCE")
      expect_bad(with({ MARKET_SOURCE = "CoinGecko" }), "MARKET_SOURCE")
   end)

   it("validates MARKET_QUOTE as a currency code", function()
      assert.are.equal("USDT", config.load(with({ MARKET_QUOTE = "USDT" })).market_quote)
      for _, q in ipairs({ "usd", "US", "USDOLLAR", "US$", "U SD" }) do
         expect_bad(with({ MARKET_QUOTE = q }), "MARKET_QUOTE")
      end
   end)

   it("validates SOURCE_URL and LOG_LEVEL", function()
      assert.are.equal("http://mock:8080", config.load(with({ SOURCE_URL = "http://mock:8080" })).source_url)
      expect_bad(with({ SOURCE_URL = "file:///etc/passwd" }), "SOURCE_URL")
      expect_bad(with({ LOG_LEVEL = "verbose" }), "LOG_LEVEL")
      assert.are.equal("debug", config.load(with({ LOG_LEVEL = "debug" })).log_level)
   end)

   it("never puts the password in an error message", function()
      local pw = "hunter2-secret"
      local bad_cases = {
         { REDIS_PORT = "x" }, { LOCK_TTL_MS = "1" }, { MAX_CONCURRENT_UPSTREAM = "2" },
         { MARKET_SOURCE = pw }, { MARKET_QUOTE = pw }, { LOG_LEVEL = pw },
      }
      for _, extra in ipairs(bad_cases) do
         extra.REDIS_PASSWORD = pw
         local _, _, detail = config.load(with(extra))
         assert.is_nil(detail:find(pw, 1, true))
      end
      local _, _, detail = config.load(fake_env({ REDIS_PASSWORD = pw }))
      assert.is_nil(detail:find(pw, 1, true))
   end)

   it("never raises, even when getenv throws", function()
      local c, code = config.load(function() error("boom") end)
      assert.is_nil(c)
      assert.are.equal("BAD_CONFIG", code)
   end)
end)
