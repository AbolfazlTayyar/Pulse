-- Patched dkjson (ADR 0007): numbers decode to their original text, never a float.
local json = require("src.vendor.dkjson")

describe("patched dkjson", function()
   describe("decode", function()
      it("keeps big and long-fraction numbers byte for byte", function()
         local t = json.decode('{"usd": 84115.123456789012345, "big": 123456789012345678901234567890}')
         assert.are.equal("84115.123456789012345", t.usd)
         assert.are.equal("123456789012345678901234567890", t.big)
      end)

      it("returns negative numbers and exponents as their original text", function()
         local t = json.decode('{"a": -1.24, "b": 1e3, "c": 2.5E-4, "d": -0.0, "e": 1E+2}')
         assert.are.equal("-1.24", t.a)
         assert.are.equal("1e3", t.b)
         assert.are.equal("2.5E-4", t.c)
         assert.are.equal("-0.0", t.d)
         assert.are.equal("1E+2", t.e)
      end)

      it("returns integers inside arrays as strings", function()
         local t = json.decode("[1, 22, 333, 0]")
         assert.are.same({ "1", "22", "333", "0" }, t)
      end)

      it("handles nested objects", function()
         local t = json.decode('{"bitcoin": {"usd": 67210.12, "usd_24h_vol": 12345.67, "usd_24h_change": -1.24}}')
         assert.are.equal("67210.12", t.bitcoin.usd)
         assert.are.equal("12345.67", t.bitcoin.usd_24h_vol)
         assert.are.equal("-1.24", t.bitcoin.usd_24h_change)
      end)

      it("decodes a CoinGecko-shaped payload with prices identical to the raw bytes", function()
         local raw = '{"bitcoin":{"usd":67210.123456789,"usd_24h_vol":28512345678.91234,'
            .. '"usd_24h_change":-1.2412345678901234,"last_updated_at":1726900000},'
            .. '"ethereum":{"usd":2600.5,"usd_24h_vol":1.5e10,"usd_24h_change":0.01}}'
         local t = json.decode(raw)
         for _, token in ipairs({ "67210.123456789", "28512345678.91234", "-1.2412345678901234", "1726900000" }) do
            assert.truthy(raw:find(token, 1, true))
         end
         assert.are.equal("67210.123456789", t.bitcoin.usd)
         assert.are.equal("28512345678.91234", t.bitcoin.usd_24h_vol)
         assert.are.equal("-1.2412345678901234", t.bitcoin.usd_24h_change)
         assert.are.equal("1.5e10", t.ethereum.usd_24h_vol)
      end)

      it("rejects malformed number tokens", function()
         for _, bad in ipairs({ "01", "1.", ".5", "-", "1e", "1.2.3", "--1", "1e+" }) do
            local v, _, err = json.decode(bad)
            assert.is_nil(v, bad)
            assert.is_string(err, bad)
         end
      end)

      it("reports invalid JSON instead of raising", function()
         local v, _, err = json.decode('{"usd": ')
         assert.is_nil(v)
         assert.is_string(err)
      end)
   end)

   describe("encode", function()
      it("keeps numeric text unchanged through encode(decode(x))", function()
         local out = json.encode((json.decode('{"p": 84115.123456789012345}')))
         assert.are.equal('{"p":"84115.123456789012345"}', out)
      end)

      it("encodes strings, booleans, integers and null", function()
         assert.are.equal('"BTC"', json.encode("BTC"))
         assert.are.equal("true", json.encode(true))
         assert.are.equal("1726900000", json.encode(1726900000))
         assert.are.equal("null", json.encode(json.null))
         assert.are.equal('{"a":null}', json.encode({ a = json.null }))
      end)

      it("tells arrays from objects, including empty ones", function()
         assert.are.equal('["a","b"]', json.encode({ "a", "b" }))
         assert.are.equal('{"k":"v"}', json.encode({ k = "v" }))
         assert.are.equal("[]", json.encode(setmetatable({}, { __jsontype = "array" })))
         assert.are.equal("{}", json.encode(setmetatable({}, { __jsontype = "object" })))
      end)

      it("never emits a newline, so one encoded value is one line", function()
         local out = json.encode({ msg = "a\nb", nested = { x = { "1", "2" } } })
         assert.is_nil(out:find("\n", 1, true))
      end)
   end)

   describe("LPeg mode", function()
      it("stays off: use_lpeg() returns the patched module", function()
         assert.are.equal(json, json.use_lpeg())
         assert.are.equal("1.10", json.use_lpeg().decode("[1.10]")[1])
      end)

      it("is not re-enabled in the source", function()
         local f = assert(io.open("src/vendor/dkjson.lua", "r"))
         local src = f:read("a")
         f:close()
         assert.truthy(src:find("local always_use_lpeg = false", 1, true))
         assert.is_nil(src:find('require%s*%(?%s*"lpeg"'))
      end)
   end)
end)
