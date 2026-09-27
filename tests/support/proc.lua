-- Test helper: runs the real `lua market.lua ...` as a child process (fixed test arguments,
-- single-quoted for the shell) and returns stdout, exit code and stderr.
local json = require("src.vendor.dkjson")
local lfs = require("lfs")
local socket = require("socket")

local M = {}

M.ROOT = lfs.currentdir()

local function q(s)
   return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function tmpname()
   return os.tmpname()
end

local function slurp(path)
   local f = io.open(path, "rb")
   if not f then return "" end
   local s = f:read("a")
   f:close()
   return s
end

-- Base env for every run; REDIS_HOST comes from the test container.
function M.env(extra)
   local e = { REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1", RES_OPTIONS = "timeout:1 attempts:1" }
   for k, v in pairs(extra or {}) do
      if v == false then e[k] = nil else e[k] = v end
   end
   return e
end

-- Shell command for one invocation. opts.fixture = true loads tests/support/fixture_http.lua.
function M.command(args, env, opts)
   opts = opts or {}
   local parts = { "cd", q(M.ROOT), "&& env -i PATH=/usr/local/bin:/usr/bin:/bin" }
   for k, v in pairs(env or M.env()) do parts[#parts + 1] = k .. "=" .. q(v) end
   parts[#parts + 1] = "lua"
   if opts.fixture then parts[#parts + 1] = "-l tests.support.fixture_http" end
   parts[#parts + 1] = "market.lua"
   for _, a in ipairs(args) do parts[#parts + 1] = q(a) end
   return table.concat(parts, " ")
end

-- Returns { out, code, err, ms, body (decoded when stdout is exactly one line), lines }.
function M.run(args, env, opts)
   opts = opts or {}
   local errf = tmpname()
   local cmd = M.command(args, env, opts) .. " 2>" .. q(errf)
   if opts.stdin then
      local inf = tmpname()
      local f = assert(io.open(inf, "wb"))
      f:write(opts.stdin)
      f:close()
      cmd = cmd .. " <" .. q(inf)
   end
   local t0 = socket.gettime()
   local p = assert(io.popen(cmd))
   local out = p:read("a")
   local _, _, code = p:close()
   local r = { out = out, code = code, err = slurp(errf), ms = (socket.gettime() - t0) * 1000, lines = {} }
   os.remove(errf)
   for line in out:gmatch("[^\n]+") do r.lines[#r.lines + 1] = line end
   if #r.lines == 1 and out:sub(-1) == "\n" then
      r.body = json.decode(r.lines[1])
   end
   return r
end

-- Starts n copies at once and waits for all. Returns a list of { out, code, body }.
function M.run_parallel(n, args, env, opts)
   local dir = tmpname()
   os.remove(dir)
   lfs.mkdir(dir)
   local cmd = M.command(args, env, opts)
   local script = "i=0; while [ $i -lt " .. n .. " ]; do (" .. cmd .. " >" .. q(dir) .. "/out.$i 2>/dev/null; echo $? >"
      .. q(dir) .. "/code.$i) & i=$((i+1)); done; wait"
   local p = assert(io.popen("sh -c " .. q(script)))
   p:read("a")
   p:close()
   local results = {}
   for i = 0, n - 1 do
      local out = slurp(dir .. "/out." .. i)
      local code = tonumber((slurp(dir .. "/code." .. i):gsub("%s", "")))
      results[#results + 1] = { out = out, code = code, body = json.decode(out) }
      os.remove(dir .. "/out." .. i)
      os.remove(dir .. "/code." .. i)
   end
   lfs.rmdir(dir)
   return results
end

return M
