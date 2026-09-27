-- cli.lua: whitelist validation of argv (ADR 0002, ADR 0021 "Fatal — caller").
local cli = require("src.cli")

local function expect_bad(argv, fragment)
   local req, code, detail = cli.parse(argv)
   assert.is_nil(req, "expected BAD_ARGS for: " .. table.concat(argv, " "))
   assert.are.equal("BAD_ARGS", code)
   assert.is_string(detail)
   if fragment then
      assert.truthy(detail:find(fragment, 1, true), "detail was: " .. detail)
   end
   return detail
end

describe("cli.parse", function()
   describe("commands", function()
      it("parses fetch and removes duplicate symbols keeping order", function()
         assert.are.same({ command = "fetch", symbols = { "BTC", "ETH" } }, cli.parse({ "fetch", "BTC,ETH,BTC" }))
         assert.are.same({ command = "fetch", symbols = { "SOL" } }, cli.parse({ "fetch", "SOL" }))
      end)

      it("parses snapshot --symbols", function()
         assert.are.same({ command = "snapshot", symbols = { "BTC", "ETH" } },
            cli.parse({ "snapshot", "--symbols", "BTC,ETH" }))
      end)

      it("parses convert with flags in any order", function()
         local want = { command = "convert", from = "BTC", to = "USDT", amount = "1.5" }
         assert.are.same(want, cli.parse({ "convert", "--from", "BTC", "--to", "USDT", "--amount", "1.5" }))
         assert.are.same(want, cli.parse({ "convert", "--amount", "1.5", "--to", "USDT", "--from", "BTC" }))
      end)

      it("parses health and daemon", function()
         assert.are.same({ command = "health" }, cli.parse({ "health" }))
         assert.are.same({ command = "daemon" }, cli.parse({ "daemon" }))
      end)

      it("rejects a missing or unknown command", function()
         expect_bad({}, "missing command")
         expect_bad({ "buy", "BTC" }, "unknown command 'buy'")
         expect_bad({ "FETCH", "BTC" }, "unknown command")
      end)

      it("rejects missing, extra, unknown and duplicate flags", function()
         expect_bad({ "fetch" }, "fetch needs")
         expect_bad({ "fetch", "BTC", "ETH" }, "no further arguments")
         expect_bad({ "snapshot" }, "missing flag --symbols")
         expect_bad({ "snapshot", "BTC" }, "unexpected argument 'BTC'")
         expect_bad({ "snapshot", "--symbols" }, "missing value for --symbols")
         expect_bad({ "snapshot", "--symbols", "BTC", "--verbose" }, "unknown flag '--verbose'")
         expect_bad({ "snapshot", "--symbols", "BTC", "--symbols", "ETH" }, "duplicate flag --symbols")
         expect_bad({ "convert", "--from", "BTC", "--to", "USD" }, "missing flag --amount")
         expect_bad({ "convert", "--from", "--to", "USD", "--amount", "1" }, "missing value for --from")
         expect_bad({ "health", "now" }, "no further arguments")
         expect_bad({ "daemon", "--port", "80" }, "no further arguments")
      end)
   end)

   describe("symbols", function()
      it("must match ^[A-Z0-9]{1,15}$", function()
         assert.truthy(cli.parse({ "fetch", "BTC,1INCH,ABCDEFGHIJKLMNO" }))
         expect_bad({ "fetch", "btc" }, "must match")
         expect_bad({ "fetch", "ABCDEFGHIJKLMNOP" }, "must match")
         expect_bad({ "fetch", "BTC-USD" }, "must match")
         expect_bad({ "fetch", "BÖC" }, "must match")
      end)

      it("rejects empty list entries", function()
         expect_bad({ "fetch", "BTC,,ETH" }, "empty symbol")
         expect_bad({ "fetch", "BTC," }, "empty symbol")
         expect_bad({ "fetch", "," }, "empty symbol")
         expect_bad({ "fetch", "" }, "at least one symbol")
      end)

      it("caps the number of distinct symbols", function()
         local many = {}
         for i = 1, cli.MAX_SYMBOLS + 1 do many[i] = "S" .. i end
         expect_bad({ "fetch", table.concat(many, ",") }, "at most")
         many[#many] = "S1" -- a duplicate does not count
         assert.truthy(cli.parse({ "fetch", table.concat(many, ",") }))
      end)
   end)

   describe("amount", function()
      local function amount(a)
         return cli.parse({ "convert", "--from", "BTC", "--to", "USD", "--amount", a })
      end

      it("accepts positive decimals within the limits", function()
         for _, a in ipairs({ "1", "1.5", "0.000000000000000001", "007", "10.10",
            string.rep("9", 30), string.rep("9", 30) .. "." .. string.rep("9", 18) }) do
            assert.are.equal(a, amount(a).amount)
         end
      end)

      it("rejects zero, signs, exponents and malformed numbers", function()
         for _, a in ipairs({ "0", "0.0", "-5", "+5", "1e3", "1E3", "1.", ".5", "1.2.3", "abc", "0x10", "1,5", "" }) do
            local req, code = amount(a)
            assert.is_nil(req, a)
            assert.are.equal("BAD_ARGS", code, a)
         end
         expect_bad({ "convert", "--from", "BTC", "--to", "USD", "--amount", "-5" }, "amount must be a positive decimal")
      end)

      it("rejects more than 30 integer digits or 18 decimals", function()
         expect_bad({ "convert", "--from", "BTC", "--to", "USD", "--amount", string.rep("1", 31) }, "30 integer digits")
         expect_bad({ "convert", "--from", "BTC", "--to", "USD", "--amount", "1." .. string.rep("1", 19) }, "18 decimals")
      end)

      it("validates --from and --to as symbols", function()
         expect_bad({ "convert", "--from", "btc", "--to", "USD", "--amount", "1" }, "must match")
         expect_bad({ "convert", "--from", "BTC", "--to", "U$D", "--amount", "1" }, "forbidden character '$'")
      end)
   end)

   describe("injection attempts", function()
      local cases = {
         { { "fetch", "BTC;rm -rf /" }, "symbol contains forbidden character ';'" },
         { { "fetch", "BTC|cat /etc/passwd" }, "forbidden character '|'" },
         { { "fetch", "BTC&&reboot" }, "forbidden character '&'" },
         { { "fetch", "$(whoami)" }, "forbidden character '$'" },
         { { "fetch", "`id`" }, "forbidden character '`'" },
         { { "fetch", "BTC>out" }, "forbidden character '>'" },
         { { "fetch", "<in" }, "forbidden character '<'" },
         { { "fetch", "BTC\\n" }, "forbidden character '\\'" },
         { { "fetch", "'BTC'" }, "forbidden character" },
         { { "fetch", '"BTC"' }, "forbidden character" },
         { { "fetch", "BTC ETH" }, "whitespace or control character" },
         { { "fetch", "BTC\nETH" }, "whitespace or control character" },
         { { "fetch", "BTC\0" }, "whitespace or control character" },
         { { "fetch", "BTC\tETH" }, "whitespace or control character" },
         { { "snapshot", "--symbols", "BTC;ls" }, "symbol contains forbidden character ';'" },
         { { "convert", "--from", "BTC", "--to", "USD", "--amount", "1;ls" }, "amount contains forbidden character ';'" },
         { { "convert", "--from", "BTC", "--to", "USD", "--amount", "1 " }, "amount contains whitespace" },
         { { "health", "(x)" }, "argument contains forbidden character '('" },
         { { "fetch;ls" }, "argument contains forbidden character ';'" },
      }
      for _, case in ipairs(cases) do
         it("rejects " .. string.format("%q", table.concat(case[1], " ")), function()
            expect_bad(case[1], case[2])
         end)
      end
   end)

   it("never raises on odd input", function()
      assert.has_no.errors(function()
         cli.parse(nil)
         cli.parse({ 42 })
         cli.parse({ "fetch", {} })
      end)
      local _, code = cli.parse({ 42 })
      assert.are.equal("BAD_ARGS", code)
   end)
end)
