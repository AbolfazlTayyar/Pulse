-- market.lua end to end: spawn the real entrypoint and check stdout + exit code (ADR 0002).
-- Arguments here are fixed test strings, single-quoted for the shell.
local json = require("src.vendor.dkjson")
local lfs = require("lfs")

local ROOT = lfs.currentdir()

local function sh_quote(s)
   return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Runs market.lua from / (not the repo) with the given env and args.
-- Returns stdout, exit code.
local function run(env, args)
   local parts = { "cd / &&", "env -i PATH=/usr/local/bin:/usr/bin:/bin" }
   for k, v in pairs(env) do parts[#parts + 1] = k .. "=" .. sh_quote(v) end
   parts[#parts + 1] = "lua " .. sh_quote(ROOT .. "/market.lua")
   for _, a in ipairs(args) do parts[#parts + 1] = sh_quote(a) end
   parts[#parts + 1] = "2>/dev/null"
   local p = assert(io.popen(table.concat(parts, " ")))
   local out = p:read("a")
   local _, _, code = p:close()
   return out, code
end

local function one_json_line(out)
   assert.are.equal(1, select(2, out:gsub("\n", "")), "expected exactly one line, got: " .. out)
   return assert(json.decode(out))
end

describe("market.lua", function()
   local env = { REDIS_HOST = "redis" }

   it("rejects bad input with one JSON line and exit 2", function()
      local cases = {
         { { "fetch", "BTC;rm -rf /" }, "symbol contains forbidden character ';'" },
         { { "convert", "--from", "BTC", "--to", "USD", "--amount", "-5" }, "amount must be a positive decimal" },
         { {}, nil },
         { { "nope" }, nil },
         { { "fetch", "$(id)" }, nil },
      }
      for _, c in ipairs(cases) do
         local out, code = run(env, c[1])
         assert.are.equal(2, code)
         local body = one_json_line(out)
         assert.are.equal(false, body.ok)
         assert.are.equal("BAD_ARGS", body.code)
         if c[2] then assert.are.equal(c[2], body.detail) end
      end
   end)

   it("reports BAD_CONFIG with exit 2 when REDIS_HOST is unset", function()
      local out, code = run({}, { "health" })
      assert.are.equal(2, code)
      local body = one_json_line(out)
      assert.are.equal("BAD_CONFIG", body.code)
      assert.are.equal("REDIS_HOST is required", body.detail)
   end)

   it("checks arguments before configuration", function()
      local out, code = run({}, { "fetch", "bad;" })
      assert.are.equal(2, code)
      assert.are.equal("BAD_ARGS", one_json_line(out).code)
   end)

   it("writes nothing but the JSON body to stdout", function()
      local out = run(env, { "fetch", "BTC;ls" })
      assert.truthy(out:match("^{.*}\n$"))
   end)
end)

describe("project hygiene", function()
   it("never uses os.execute or io.popen in src/ or market.lua", function()
      local function scan(path, hits)
         local mode = lfs.attributes(path, "mode")
         if mode == "directory" then
            for name in lfs.dir(path) do
               if name ~= "." and name ~= ".." then scan(path .. "/" .. name, hits) end
            end
         elseif path:match("%.lua$") then
            local n = 0
            for line in io.lines(path) do
               n = n + 1
               if line:find("os%.execute") or line:find("io%.popen") then
                  hits[#hits + 1] = path .. ":" .. n
               end
            end
         end
         return hits
      end
      local hits = scan("src", scan("market.lua", {}))
      assert.are.same({}, hits)
   end)
end)
