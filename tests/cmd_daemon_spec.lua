-- `lua market.lua daemon` for real: NDJSON in, one JSON line out per request (ADR 0014).
local proc = require("tests.support.proc")
local redis = require("src.redis_client")
local snapshot = require("src.snapshot")
local json = require("src.vendor.dkjson")
local socket = require("socket")

local SRC = "coingecko"
local FIXTURE = "http://fixture/coingecko/simple_price.json"

local function clear(r)
   for _, k in ipairs(r:call("KEYS", "mkt:*" .. SRC .. "*")) do
      if not k:find("^mkt:stats:") then r:call("DEL", k) end
   end
end

local function decode_lines(out)
   local t = {}
   for line in out:gmatch("[^\n]+") do t[#t + 1] = assert(json.decode(line), line) end
   return t
end

describe("daemon command", function()
   local r

   before_each(function()
      r = assert(redis.connect(os.getenv("REDIS_HOST"), 6379, 500))
      clear(r)
   end)
   after_each(function()
      clear(r)
      r:close()
   end)

   it("answers every line in order, echoes ids and serves repeats from memory", function()
      local before = snapshot.get_vendor_calls(r, SRC)
      local input = table.concat({
         '{"id":"1","command":"fetch","symbols":["BTC"]}',
         '{"id":"2","command":"snapshot","symbols":["BTC"]}',
         "not json",
         "",
         '{"id":"4","command":"convert","from":"BTC","to":"USD","amount":"2"}',
         '{"id":"5","command":"fetch","symbols":["BTC;ls"]}',
         '{"id":"6","command":"daemon"}',
         '{"id":"7","command":"fetch","symbols":["BTC"],"extra":1}',
         '{"id":"8","command":"health"}',
         '{"id":"9","command":"fetch","symbols":["BTC"]}',
      }, "\n") .. "\n"
      local res = proc.run({ "daemon" }, proc.env({ SOURCE_URL = FIXTURE }), { fixture = true, stdin = input })
      assert.are.equal(0, res.code)
      local out = decode_lines(res.out)
      assert.are.equal(9, #out) -- the blank line gets no answer

      assert.are.equal("1", out[1].id)
      assert.are.equal("miss", out[1].meta.cache)
      assert.are.equal("2", out[2].id)
      assert.are.equal("memory", out[2].meta.cache)
      assert.are.equal("0", out[2].meta.redis_ms)
      assert.truthy(res.out:find('{"id":null,"ok":false,"code":"BAD_ARGS","detail":"invalid JSON"}', 1, true))
      assert.are.equal("convert.v1", out[4].schema)
      assert.are.equal("memory", out[4].meta.cache)
      assert.are.equal("BAD_ARGS", out[5].code)
      assert.are.equal("5", out[5].id)
      assert.are.equal("BAD_ARGS", out[6].code)
      assert.are.equal("BAD_ARGS", out[7].code)
      assert.are.equal("health.v1", out[8].schema)
      assert.are.equal("memory", out[9].meta.cache)
      assert.are.equal(before + 1, snapshot.get_vendor_calls(r, SRC))

      assert.truthy(res.err:find('"req":"4"', 1, true)) -- logs carry the request id
      assert.truthy(res.err:find('"event":"daemon_end"', 1, true))
   end)

   it("keeps running when Redis becomes unreachable mid-session, and recovers", function()
      local outfile = os.tmpname()
      local cmd = proc.command({ "daemon" }, proc.env({ SOURCE_URL = FIXTURE, REDIS_TIMEOUT_MS = "200" }),
         { fixture = true }) .. " >" .. outfile .. " 2>/dev/null"
      local p = assert(io.popen(cmd, "w"))
      local function send(line)
         p:write(line, "\n")
         p:flush()
         socket.sleep(0.4)
      end
      send('{"id":"a","command":"fetch","symbols":["BTC"]}')
      r:call("CLIENT", "PAUSE", "1500", "ALL") -- Redis stops answering anyone for 1.5 s
      local paused_at = socket.gettime()
      send('{"id":"b","command":"snapshot","symbols":["BTC"]}')  -- LRU still answers
      send('{"id":"c","command":"health"}')                      -- needs Redis
      send('{"id":"d","command":"snapshot","symbols":["ETH"]}')  -- needs Redis
      socket.sleep(math.max(0, 1.6 - (socket.gettime() - paused_at)))
      send('{"id":"e","command":"health"}')                      -- Redis is back
      local _, _, code = p:close()
      local f = assert(io.open(outfile))
      local out = decode_lines(f:read("a"))
      f:close()
      os.remove(outfile)

      assert.are.equal(0, code)
      assert.are.equal(5, #out)
      assert.are.equal("miss", out[1].meta.cache)
      assert.are.equal("memory", out[2].meta.cache)
      assert.is_true(out[2].ok)
      assert.are.equal("health.v1", out[3].schema)
      assert.is_false(out[3].ok)
      assert.is_false(out[3].redis.ok)
      assert.are.equal("REDIS_UNAVAILABLE", out[4].code)
      assert.are.equal("e", out[5].id)
      assert.is_true(out[5].ok)
   end)
end)
