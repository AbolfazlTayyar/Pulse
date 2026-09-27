-- Binance and Kraken adapters against hand-written fixtures (both APIs are blocked from the dev
-- network, ADR 0006). The items they produce must have exactly CoinGecko's shape.
local source = require("src.source")
local normalize = require("src.normalize")
local decimal = require("src.decimal")
local log = require("src.log")

local function fixture(name)
   local f = assert(io.open("tests/fixtures/" .. name, "rb"))
   local s = f:read("a")
   f:close()
   return s
end

local function keys(t)
   local k = {}
   for key in pairs(t) do k[#k + 1] = key end
   table.sort(k)
   return k
end

describe("binance and kraken adapters", function()
   local real_http_get, urls

   local function stub(file, status)
      source.http_get = function(url)
         urls[#urls + 1] = url
         return { kind = "ok", status = status or 200, body = fixture(file), headers = {}, http_ms = 5 }
      end
   end

   before_each(function()
      real_http_get = source.http_get
      urls = {}
      log._set_stream(assert(io.tmpfile()))
   end)
   after_each(function()
      source.http_get = real_http_get
      log._set_stream(nil)
   end)

   describe("binance", function()
      it("fetches a batch of USDT pairs and labels them USDT, never USD", function()
         stub("binance/ticker_24hr.json")
         local a = source.get("binance")
         assert.are.equal("USDT", a.effective_quote("USD"))
         local rows, errors, info = a.fetch({ "BTC", "ETH" }, "USD", 2000)
         assert.are.equal(1, #urls)
         assert.truthy(urls[1]:find("/api/v3/ticker/24hr?symbols=%5B%22BTCUSDT%22%2C%22ETHUSDT%22%5D", 1, true))
         assert.are.equal("ok", info.kind)
         assert.are.same({}, errors)
         assert.are.same({
            symbol = "BTC", quote = "USDT", price = "67210.12000000",
            volume_24h = "1232468812.34567890", change_24h_pct = "-1.243",
         }, rows[1])
         assert.are.equal("ETH", rows[2].symbol)
      end)

      it("uses a non-USD quote as-is", function()
         assert.are.equal("EUR", source.get("binance").effective_quote("EUR"))
      end)

      it("reports unknown symbols without putting them in the batch", function()
         stub("binance/ticker_24hr.json")
         local rows, errors = source.get("binance").fetch({ "BTC", "FAKECOIN", "USDT" }, "USD", 2000)
         assert.are.equal(1, #rows)
         assert.are.equal(2, #errors)
         assert.are.equal("UNKNOWN_SYMBOL", errors[1].code)
         assert.falsy(urls[1]:find("FAKECOIN", 1, true))
         local _, errs = source.get("binance").fetch({ "BTC", "SOL" }, "USD", 2000) -- SOL not in fixture
         assert.are.same({ { symbol = "SOL", code = "UNKNOWN_SYMBOL", detail = "not returned by binance (SOLUSDT)" } }, errs)
      end)

      it("lets normalize catch missing fields", function()
         stub("binance/missing_field.json")
         local rows = source.get("binance").fetch({ "BTC", "ETH" }, "USD", 2000)
         local items, errors = normalize.build_items(rows, 1726900000)
         assert.are.equal(1, #items)
         assert.are.same({ { symbol = "BTC", code = "BAD_PAYLOAD", detail = "missing field price" } }, errors)
      end)

      it("classifies a 400 and a garbage body", function()
         stub("coingecko/html_error.html", 400)
         assert.are.equal("http_error", select(3, source.get("binance").fetch({ "BTC" }, "USD", 2000)).kind)
         stub("coingecko/html_error.html", 200)
         assert.are.equal("bad_payload", select(3, source.get("binance").fetch({ "BTC" }, "USD", 2000)).kind)
      end)
   end)

   describe("kraken", function()
      it("maps symbols, reads Kraken's pair names and computes the change with decimal math", function()
         stub("kraken/ticker.json")
         local rows, errors, info = source.get("kraken").fetch({ "BTC", "ETH", "SOL" }, "USD", 2000)
         assert.truthy(urls[1]:find("/0/public/Ticker?pair=XBTUSD,ETHUSD,SOLUSD", 1, true))
         assert.are.equal("ok", info.kind)
         assert.are.same({}, errors)
         assert.are.same({
            symbol = "BTC", quote = "USD", price = "67210.12000",
            volume_24h = "12345.67", change_24h_pct = "-1.24",
         }, rows[1])
         -- (67210.12 - 68055) / 68055 * 100 = -1.24146646...
         assert.are.equal(tostring(decimal.div(decimal.mul(decimal.sub("67210.12", "68055"), "100"), "68055", 2)),
            rows[1].change_24h_pct)
         assert.are.equal("0.53", rows[2].change_24h_pct) -- (3120.55 - 3104) / 3104 * 100 = 0.5331...
         assert.are.equal("1.79", rows[3].change_24h_pct) -- (142.5 - 140) / 140 * 100 = 1.7857...
         assert.are.equal("142.50000", rows[3].price)
      end)

      it("reports unknown symbols", function()
         stub("kraken/ticker.json")
         local rows, errors = source.get("kraken").fetch({ "BTC", "FAKECOIN" }, "USD", 2000)
         assert.are.equal(1, #rows)
         assert.are.same({ { symbol = "FAKECOIN", code = "UNKNOWN_SYMBOL", detail = "not supported by kraken" } }, errors)
         local _, errs = source.get("kraken").fetch({ "ADA" }, "USD", 2000) -- mapped, but not in the answer
         assert.are.same({ { symbol = "ADA", code = "UNKNOWN_SYMBOL", detail = "not returned by kraken" } }, errs)
      end)

      it("lets normalize catch a missing price and an unusable open", function()
         stub("kraken/missing_field.json")
         local rows = source.get("kraken").fetch({ "BTC", "ETH" }, "USD", 2000)
         local items, errors = normalize.build_items(rows, 1726900000)
         assert.are.equal(0, #items)
         assert.are.same({
            { symbol = "BTC", code = "BAD_PAYLOAD", detail = "missing field price" },
            { symbol = "ETH", code = "BAD_PAYLOAD", detail = "missing field change_24h_pct" },
         }, errors)
      end)

      it("maps Kraken's error array", function()
         stub("kraken/error_rate_limit.json")
         local rows, _, info = source.get("kraken").fetch({ "BTC" }, "USD", 2000)
         assert.are.same({}, rows)
         assert.are.equal("rate_limited", info.kind)
      end)
   end)

   it("all three sources produce items with exactly the same fields", function()
      local shapes = {}
      for name, file in pairs({ coingecko = "coingecko/simple_price.json", binance = "binance/ticker_24hr.json",
         kraken = "kraken/ticker.json" }) do
         stub(file)
         local rows = source.get(name).fetch({ "BTC" }, "USD", 2000)
         local items = normalize.build_items(rows, 1726900000)
         assert.are.equal(1, #items, name)
         shapes[name] = keys(items[1])
         for _, f in ipairs({ "price", "volume_24h", "change_24h_pct", "quote", "symbol" }) do
            assert.are.equal("string", type(items[1][f]), name .. "." .. f)
         end
      end
      assert.are.same(shapes.coingecko, shapes.binance)
      assert.are.same(shapes.coingecko, shapes.kraken)
   end)
end)
