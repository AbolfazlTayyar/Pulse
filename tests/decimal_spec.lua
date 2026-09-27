-- decimal.lua (ADR 0007, ADR 0020).
-- Reference values were produced with Python 3.11's decimal module (prec=200, exact arithmetic,
-- quantize(..., rounding=ROUND_HALF_EVEN) for rounding), e.g.
--   str((Decimal("1.5") * Decimal("67210.12") / Decimal("1.00002813")).quantize(Decimal("1e-8"),
--       rounding=ROUND_HALF_EVEN))  ->  "100812.34414876"
-- Python prints some results in exponent form (2E-8); they are written here as plain decimals.
local decimal = require("src.decimal")

local function s(d) return tostring(d) end

describe("decimal", function()
   describe("parse", function()
      it("accepts signed decimals and keeps their scale", function()
         assert.are.equal("67210.12", s(decimal.parse("67210.12")))
         assert.are.equal("-1.24", s(decimal.parse("-1.24")))
         assert.are.equal("0.000000000000000001", s(decimal.parse("0.000000000000000001")))
         assert.are.equal("12.3400", s(decimal.parse("12.3400")))
         assert.are.equal("7.500", s(decimal.parse("007.500")))
         assert.are.equal("0", s(decimal.parse("-0")))
      end)

      it("accepts vendor exponent notation", function()
         assert.are.equal("1000", s(decimal.parse("1e3")))
         assert.are.equal("0.00025", s(decimal.parse("2.5E-4")))
         assert.are.equal("-150", s(decimal.parse("-1.5e+2")))
         assert.are.equal("12", s(decimal.parse("12E0")))
      end)

      it("rejects anything else with nil, err", function()
         for _, bad in ipairs({ "", "abc", "1.", ".5", "+1", "1.2.3", "1e", "1e+", "--1", " 1", "1 ",
            "1,5", "0x10", "inf", "nan", "1e99999", "1e-5000" }) do
            local d, err = decimal.parse(bad)
            assert.is_nil(d, bad)
            assert.is_string(err, bad)
         end
         assert.is_nil(decimal.parse(12))
         assert.is_nil(decimal.parse(nil))
      end)
   end)

   describe("add / sub", function()
      it("is exact where floats are not", function()
         assert.are.equal("0.3", s(decimal.add("0.1", "0.2")))
      end)

      it("handles signs and carries", function()
         assert.are.equal("-2.125", s(decimal.add("-5.25", "3.125")))
         assert.are.equal("-0.3", s(decimal.add("-0.1", "-0.2")))
         assert.are.equal("0.9999999", s(decimal.sub("1", "0.0000001")))
         assert.are.equal("-2.125", s(decimal.sub("3.125", "5.25")))
         assert.are.equal("10000000", s(decimal.sub("9999999", "-1")))
         assert.are.equal("0.00", s(decimal.sub("1.25", "1.25")))
      end)

      it("keeps leading and trailing zeros meaningful only as scale", function()
         assert.are.equal("7.500", s(decimal.add("007.500", "0.0")))
         assert.are.equal("0.00", s(decimal.add("000", "0.00")))
      end)
   end)

   describe("mul", function()
      it("is exact and cannot overflow", function()
         assert.are.equal("8297545604334434560433443456035046.80",
            s(decimal.mul("123456789012345678901234567890", "67210.12")))
         assert.are.equal("9999999999999999999800000000000000000001",
            s(decimal.mul("99999999999999999999", "99999999999999999999")))
      end)

      it("handles signs and tiny values", function()
         assert.are.equal("-100815.180", s(decimal.mul("-1.5", "67210.12")))
         assert.are.equal("0.0000000000000001", s(decimal.mul("0.00000001", "0.00000001")))
      end)
   end)

   describe("div", function()
      it("rounds once, half to even", function()
         assert.are.equal("0.33333333", s(decimal.div("1", "3", 8)))
         assert.are.equal("0.66666667", s(decimal.div("2", "3", 8)))
         assert.are.equal("-0.66666667", s(decimal.div("-2", "3", 8)))
      end)

      it("matches the ADR 0020 example", function()
         local amount_times_price = decimal.mul("1.5", "67210.12")
         assert.are.equal("100812.34414876", s(decimal.div(amount_times_price, "1.00002813", 8)))
         assert.are.equal("67208.22943251", s(decimal.div("67210.12", "1.00002813", 8)))
         assert.are.equal("0.99997187", s(decimal.div("1", "1.00002813", 8)))
      end)

      it("handles huge values that overflow 2^63", function()
         local x = decimal.mul("123456789012345678901234567890.123456789012345678", "67210.12")
         assert.are.equal("6745972036044255740189791427677515728133.60523130", s(decimal.div(x, "0.00000123", 8)))
      end)

      it("breaks exact ties toward the even digit", function()
         assert.are.equal("0.12", s(decimal.div("1", "8", 2)))  -- 0.125
         assert.are.equal("0.38", s(decimal.div("3", "8", 2)))  -- 0.375
         assert.are.equal("-0.12", s(decimal.div("-1", "8", 2)))
         assert.are.equal("-0.38", s(decimal.div("-3", "8", 2)))
      end)

      it("returns nil, err on division by zero", function()
         local d, err = decimal.div("1", "0.000", 8)
         assert.is_nil(d)
         assert.are.equal("division by zero", err)
      end)
   end)

   describe("round / format", function()
      it("rounds ties half to even in both directions", function()
         assert.are.equal("0.00000002", decimal.format("0.000000025", 8))
         assert.are.equal("0.00000004", decimal.format("0.000000035", 8))
         assert.are.equal("-0.00000002", decimal.format("-0.000000025", 8))
         assert.are.equal("-0.00000004", decimal.format("-0.000000035", 8))
         assert.are.equal("2", decimal.format("2.5", 0))
         assert.are.equal("4", decimal.format("3.5", 0))
         assert.are.equal("0", decimal.format("0.5", 0))
         assert.are.equal("100.00", decimal.format("99.995", 2))
         assert.are.equal("99.98", decimal.format("99.985", 2))
      end)

      it("rounds non-ties to nearest", function()
         assert.are.equal("1", decimal.format("1.4999999", 0))
         assert.are.equal("2", decimal.format("1.5000001", 0))
         assert.are.equal("0.00000003", decimal.format("0.0000000250000001", 8))
      end)

      it("pads to exactly `scale` decimals", function()
         assert.are.equal("1.5000", decimal.format("1.5", 4))
         assert.are.equal("67210.12000000", decimal.format("67210.12", 8))
      end)

      it("never prints negative zero", function()
         -- Python keeps the sign ("-0E-8"); a price or amount of "-0.00000000" is never useful.
         assert.are.equal("0.00000000", decimal.format("-0.000000001", 8))
      end)
   end)

   describe("compare / predicates", function()
      it("compares across scales and signs", function()
         assert.are.equal(0, decimal.compare("1.50", "1.5"))
         assert.are.equal(-1, decimal.compare("-2", "1"))
         assert.are.equal(1, decimal.compare("0.0000001", "0"))
         assert.are.equal(-1, decimal.compare("99999999999999999999", "100000000000000000000"))
      end)

      it("is_positive and is_zero", function()
         assert.is_true(decimal.is_positive("0.00000001"))
         assert.is_false(decimal.is_positive("0"))
         assert.is_false(decimal.is_positive("-1"))
         assert.is_true(decimal.is_zero("0.000"))
         assert.is_false(decimal.is_zero("-0.001"))
      end)
   end)

   it("never calls tonumber() or uses floats in its source", function()
      local f = assert(io.open("src/decimal.lua", "r"))
      local src = f:read("a"):gsub("%-%-[^\n]*", "") -- code only, not comments
      f:close()
      assert.is_nil(src:find("tonumber", 1, true))
      assert.is_nil(src:find("math%.floor"))
      assert.is_nil(src:find("[^/]/[^/]"), "found a float division '/'")
   end)
end)
