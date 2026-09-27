-- output.lua (stdout, ADR 0002) and log.lua (stderr, ADR 0019).
local json = require("src.vendor.dkjson")
local output = require("src.output")
local log = require("src.log")
local lfs = require("lfs")

local function capture()
   local f = assert(io.tmpfile())
   return f, function()
      f:seek("set", 0)
      return f:read("a")
   end
end

local function lines(s)
   local t = {}
   for l in s:gmatch("[^\n]+") do t[#t + 1] = l end
   return t
end

describe("output", function()
   local read
   before_each(function()
      local f
      f, read = capture()
      output._set_stream(f)
   end)
   after_each(function() output._set_stream(nil) end)

   it("emits one table as one JSON line", function()
      assert.is_true(output.emit({ ok = true }))
      assert.are.equal('{"ok":true}\n', read())
   end)

   it("keeps the top-level keys in a stable order", function()
      output.emit({ meta = { partial = false }, items = {}, ok = true, schema = "ticker.v1" })
      local out = read()
      assert.truthy(out:find('^{"ok":true,"schema":"ticker.v1","items":'))
      assert.are.equal(1, #lines(out))
   end)

   it("builds the minimal error body", function()
      assert.are.same({ ok = false, code = "BAD_ARGS", detail = "x" }, output.error_body("BAD_ARGS", "x"))
      output.emit(output.error_body("BAD_ARGS", "multi\nline"))
      local out = read()
      assert.are.equal(1, #lines(out))
      assert.are.same({ ok = false, code = "BAD_ARGS", detail = "multi\nline" }, (json.decode(out)))
   end)

   it("returns an error instead of raising or writing when the body can't be encoded", function()
      local ok, err = output.emit({ f = function() end })
      assert.is_nil(ok)
      assert.is_string(err)
      assert.are.equal("", read())
   end)
end)

describe("log", function()
   local read
   before_each(function()
      local f
      f, read = capture()
      log._set_stream(f)
      log.set_level("info")
      log.set_request(nil)
   end)
   after_each(function() log._set_stream(nil) end)

   it("writes one JSON object per line with ts, level, inv and event first", function()
      log.info("cache_hit", { symbols = { "BTC" } })
      local out = lines(read())
      assert.are.equal(1, #out)
      assert.truthy(out[1]:match(
         '^{"ts":"%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ","level":"info","inv":"%x%x%x%x%x%x%x%x","event":"cache_hit"'))
      assert.are.same({ "BTC" }, json.decode(out[1]).symbols)
   end)

   it("keeps the same inv for the whole process", function()
      log.info("a")
      log.warn("b")
      local out = lines(read())
      assert.are.equal(json.decode(out[1]).inv, json.decode(out[2]).inv)
      assert.are.equal(log.invocation_id(), json.decode(out[1]).inv)
   end)

   it("adds req when a daemon request id is set", function()
      log.set_request("r-42")
      log.info("x")
      assert.are.equal("r-42", json.decode(read()).req)
   end)

   it("filters by level", function()
      log.set_level("warn")
      log.debug("d")
      log.info("i")
      log.warn("w")
      log.error("e")
      local out = lines(read())
      assert.are.equal(2, #out)
      assert.are.equal("w", json.decode(out[1]).event)
      assert.are.equal("e", json.decode(out[2]).event)
   end)

   it("never writes secret fields, even nested", function()
      log.info("x", { password = "hunter2", auth = "hunter3", nested = { redis_password = "hunter4" } })
      local out = read()
      assert.is_nil(out:find("hunter", 1, true))
      assert.truthy(out:find("[redacted]", 1, true))
   end)

   it("does not let fields overwrite ts, level, inv or event", function()
      log.info("real", { event = "fake", level = "error", inv = "00000000" })
      local rec = json.decode(read())
      assert.are.equal("real", rec.event)
      assert.are.equal("info", rec.level)
      assert.are_not.equal("00000000", rec.inv)
   end)

   it("keeps one event on one line when a value contains a newline", function()
      log.error("redis_error", { detail = "line1\nline2" })
      assert.are.equal(1, #lines(read()))
   end)

   it("swallows write failures", function()
      local closed = assert(io.tmpfile())
      closed:close()
      log._set_stream(closed)
      assert.has_no.errors(function() log.error("x", { a = 1 }) end)
   end)
end)

describe("stdout discipline", function()
   -- Only src/output.lua may write to stdout (ADR 0002). A stray print() breaks host parsing.
   local FORBIDDEN = { "print%s*%(", "io%.write", "io%.stdout", "io%.output" }

   local function lua_files(dir, acc)
      for name in lfs.dir(dir) do
         if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
               lua_files(path, acc)
            elseif name:match("%.lua$") then
               acc[#acc + 1] = path
            end
         end
      end
      return acc
   end

   it("finds no stdout writes outside src/output.lua", function()
      local files = lua_files("src", { "market.lua" })
      local offenders = {}
      for _, path in ipairs(files) do
         if path ~= "src/output.lua" then
            local n = 0
            for line in io.lines(path) do
               n = n + 1
               for _, pat in ipairs(FORBIDDEN) do
                  if line:find(pat) then
                     offenders[#offenders + 1] = path .. ":" .. n .. ": " .. line
                  end
               end
            end
         end
      end
      assert.are.same({}, offenders)
   end)
end)
