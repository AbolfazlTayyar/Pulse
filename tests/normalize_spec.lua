-- normalize.lua: structural validation of vendor rows (ADR 0021, ADR 0010).
local normalize = require("src.normalize")
local log = require("src.log")

local AS_OF = 1726900000

local function row(overrides)
   local r = { symbol = "BTC", quote = "USD", price = "67210.12", volume_24h = "12345.67", change_24h_pct = "-1.24" }
   for k, v in pairs(overrides or {}) do
      if v == "<nil>" then r[k] = nil else r[k] = v end
   end
   return r
end

local function expect_bad(r, detail)
   local item, err = normalize.validate_row(r, AS_OF)
   assert.is_nil(item)
   assert.are.equal(detail, err)
end

describe("normalize", function()
   local logs
   before_each(function()
      logs = assert(io.tmpfile())
      log._set_stream(logs)
   end)
   after_each(function() log._set_stream(nil) end)

   describe("validate_row", function()
      it("turns a good row into a ticker.v1 item, keeping the vendor's text", function()
         assert.are.same({
            symbol = "BTC", quote = "USD", price = "67210.12", volume_24h = "12345.67",
            change_24h_pct = "-1.24", as_of_unix = AS_OF, stale = false,
         }, normalize.validate_row(row(), AS_OF))
         local item = normalize.validate_row(row({ price = "84115.123456789012345", volume_24h = "1.5e10" }), AS_OF)
         assert.are.equal("84115.123456789012345", item.price)
         assert.are.equal("1.5e10", item.volume_24h)
      end)

      it("drops fields that are not part of ticker.v1", function()
         local item = normalize.validate_row(row({ extra = "x" }), AS_OF)
         assert.is_nil(item.extra)
      end)

      it("rejects each missing field", function()
         for _, f in ipairs({ "symbol", "quote", "price", "volume_24h", "change_24h_pct" }) do
            expect_bad(row({ [f] = "<nil>" }), "missing field " .. f)
         end
      end)

      it("rejects non-string and non-decimal values", function()
         expect_bad(row({ price = "abc" }), "price is not a decimal")
         expect_bad(row({ volume_24h = "" }), "volume_24h is not a decimal")
         expect_bad(row({ change_24h_pct = "1,5" }), "change_24h_pct is not a decimal")
         expect_bad(row({ price = 67210.12 }), "price is not a string")
         expect_bad(row({ symbol = "btc" }), "symbol is invalid")
         expect_bad(row({ quote = "usd" }), "quote is invalid")
      end)

      it("requires price > 0 but allows a negative change", function()
         expect_bad(row({ price = "0" }), "price must be > 0")
         expect_bad(row({ price = "0.000" }), "price must be > 0")
         expect_bad(row({ price = "-1" }), "price must be > 0")
         assert.truthy(normalize.validate_row(row({ change_24h_pct = "-99.9" }), AS_OF))
         assert.truthy(normalize.validate_row(row({ price = "0.00000001" }), AS_OF))
      end)

      it("rejects a row that is not even a table", function()
         expect_bad("BTC", "row is not an object")
         expect_bad(42, "row is not an object")
      end)
   end)

   describe("build_items", function()
      it("keeps good rows and reports one BAD_PAYLOAD for a poison row", function()
         local items, errors = normalize.build_items({
            row({ symbol = "BTC" }),
            row({ symbol = "ETH", price = "0" }),
            row({ symbol = "SOL", price = "142.5" }),
         }, AS_OF)
         assert.are.equal(2, #items)
         assert.are.equal("BTC", items[1].symbol)
         assert.are.equal("SOL", items[2].symbol)
         assert.are.same({ { symbol = "ETH", code = "BAD_PAYLOAD", detail = "price must be > 0" } }, errors)
         logs:seek("set", 0)
         local out = logs:read("a")
         assert.truthy(out:find('"event":"symbol_error"', 1, true))
         assert.truthy(out:find('"symbol":"ETH"', 1, true))
      end)

      it("survives a row that throws while being validated", function()
         local poison = setmetatable({}, { __index = function() error("boom") end })
         local items, errors = normalize.build_items({ row({ symbol = "BTC" }), poison, "junk", row({ symbol = "SOL" }) }, AS_OF)
         assert.are.equal(2, #items)
         assert.are.equal(2, #errors)
         assert.are.equal("BAD_PAYLOAD", errors[1].code)
         assert.truthy(errors[1].detail:find("could not be validated", 1, true))
         assert.is_nil(errors[1].symbol)
         assert.are.equal("row is not an object", errors[2].detail)
      end)

      it("handles an empty batch", function()
         local items, errors = normalize.build_items({}, AS_OF)
         assert.are.same({}, items)
         assert.are.same({}, errors)
      end)
   end)
end)
