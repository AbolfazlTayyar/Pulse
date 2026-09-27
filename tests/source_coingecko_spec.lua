-- CoinGecko adapter with a stubbed HTTP layer (fixtures in tests/fixtures/coingecko/), plus
-- real sockets for timeout and connect errors.
local source = require("src.source")
local coingecko = require("src.source.coingecko")
local normalize = require("src.normalize")
local log = require("src.log")

local function fixture(name)
   local f = assert(io.open("tests/fixtures/coingecko/" .. name, "rb"))
   local s = f:read("a")
   f:close()
   return s
end

describe("coingecko adapter", function()
   local real_http_get, calls

   local function stub(status, body, headers)
      source.http_get = function(url, timeout_ms)
         calls[#calls + 1] = { url = url, timeout_ms = timeout_ms }
         return { kind = "ok", status = status, body = body, headers = headers or {}, http_ms = 7 }
      end
   end

   before_each(function()
      real_http_get = source.http_get
      calls = {}
      log._set_stream(assert(io.tmpfile()))
   end)
   after_each(function()
      source.http_get = real_http_get
      log._set_stream(nil)
   end)

   it("is found through the registry", function()
      local a = source.get("coingecko")
      assert.are.equal("coingecko", a.name)
      assert.are.equal(coingecko.DEFAULT_URL, a.base_url)
      assert.are.equal("http://mock", source.get("coingecko", "http://mock/").base_url)
      assert.is_nil(source.get("nope"))
   end)

   it("asks once for every symbol and keeps prices as the raw text", function()
      local body = fixture("simple_price.json")
      stub(200, body)
      local rows, errors, info = source.get("coingecko").fetch({ "BTC", "ETH" }, "USD", 2000)
      assert.are.equal(1, #calls)
      assert.are.equal(2000, calls[1].timeout_ms)
      assert.truthy(calls[1].url:find("/simple/price?ids=bitcoin,ethereum&vs_currencies=usd"
         .. "&include_24hr_vol=true&include_24hr_change=true", 1, true))
      assert.are.same({}, errors)
      assert.are.same({ kind = "ok", status = 200, http_ms = 7 }, info)
      assert.are.same({
         symbol = "BTC", quote = "USD", price = "84115.123456789012345",
         volume_24h = "31914880000.5", change_24h_pct = "-1.2412345678901234",
      }, rows[1])
      assert.truthy(body:find(rows[1].price, 1, true))
      assert.are.equal("3120.55", rows[2].price)
   end)

   it("parses the recorded live response byte for byte", function()
      local body = fixture("recorded_2026-09-27.json")
      stub(200, body)
      local rows = source.get("coingecko").fetch({ "BTC", "ETH" }, "USD", 2000)
      assert.are.equal("84449", rows[1].price)
      assert.are.equal("21971999782.491917", rows[1].volume_24h)
      assert.are.equal("-0.22202209552149546", rows[2].change_24h_pct)
      for _, r in ipairs(rows) do
         assert.truthy(body:find(r.price, 1, true))
         assert.truthy(body:find(r.volume_24h, 1, true))
      end
   end)

   it("reports an unmapped symbol without asking the vendor, and a missing one after", function()
      stub(200, fixture("simple_price.json"))
      local rows, errors = source.get("coingecko").fetch({ "BTC", "FAKECOIN" }, "USD", 2000)
      assert.are.equal(1, #rows)
      assert.are.same({ { symbol = "FAKECOIN", code = "UNKNOWN_SYMBOL", detail = "not supported by coingecko" } }, errors)
      assert.falsy(calls[1].url:find("FAKECOIN", 1, true))

      calls = {}
      local _, errs2, info = source.get("coingecko").fetch({ "FAKECOIN" }, "USD", 2000)
      assert.are.equal(0, #calls)
      assert.are.equal(1, #errs2)
      assert.are.equal("ok", info.kind)

      stub(200, '{"bitcoin":{"usd":1,"usd_24h_vol":1,"usd_24h_change":1}}')
      local _, errs3 = source.get("coingecko").fetch({ "BTC", "DOGE" }, "USD", 2000)
      assert.are.same({ { symbol = "DOGE", code = "UNKNOWN_SYMBOL", detail = "not returned by coingecko" } }, errs3)
   end)

   it("passes rows with missing fields on, and normalize turns them into BAD_PAYLOAD", function()
      stub(200, fixture("missing_field.json"))
      local rows = source.get("coingecko").fetch({ "BTC", "ETH" }, "USD", 2000)
      local items, errors = normalize.build_items(rows, 1726900000)
      assert.are.equal(0, #items)
      assert.are.same({
         { symbol = "BTC", code = "BAD_PAYLOAD", detail = "missing field volume_24h" },
         { symbol = "ETH", code = "BAD_PAYLOAD", detail = "missing field price" },
      }, errors)
   end)

   it("classifies 429 with Retry-After", function()
      stub(429, fixture("rate_limited_429.json"), { ["retry-after"] = "12" })
      local rows, _, info = source.get("coingecko").fetch({ "BTC" }, "USD", 2000)
      assert.are.same({}, rows)
      assert.are.equal("rate_limited", info.kind)
      assert.are.equal("12", info.retry_after)
      assert.are.equal(429, info.status)
   end)

   it("classifies 5xx as retryable and 4xx as not", function()
      stub(500, "oops")
      local _, _, info = source.get("coingecko").fetch({ "BTC" }, "USD", 2000)
      assert.are.equal("server_error", info.kind)
      assert.are.equal("coingecko: HTTP 500", info.detail)
      assert.is_true(source.RETRYABLE[info.kind])
      stub(404, "nope")
      _, _, info = source.get("coingecko").fetch({ "BTC" }, "USD", 2000)
      assert.are.equal("http_error", info.kind)
      assert.is_nil(source.RETRYABLE[info.kind])
   end)

   it("reports an undecodable or wrong-shaped body as bad_payload", function()
      for _, body in ipairs({ fixture("html_error.html"), "", "[1,2]", '"text"', fixture("rate_limited_429.json") }) do
         stub(200, body)
         local rows, _, info = source.get("coingecko").fetch({ "BTC" }, "USD", 2000)
         assert.are.same({}, rows)
         assert.are.equal("bad_payload", info.kind, body)
      end
   end)

   describe("real sockets", function()
      before_each(function() source.http_get = real_http_get end)

      it("times out against an unroutable address", function()
         local rows, _, info = source.get("coingecko", "http://10.255.255.1").fetch({ "BTC" }, "USD", 300)
         assert.are.same({}, rows)
         assert.are.equal("timeout", info.kind)
         assert.is_true(info.http_ms >= 290 and info.http_ms < 1500, tostring(info.http_ms))
         assert.is_nil(source.RETRYABLE[info.kind])
      end)

      it("reports a connect error for a closed port", function()
         local _, _, info = source.get("coingecko", "http://127.0.0.1:1").fetch({ "BTC" }, "USD", 300)
         assert.are.equal("connect", info.kind)
         assert.is_true(source.RETRYABLE[info.kind])
      end)
   end)
end)
