-- daemon: NDJSON requests on stdin, one JSON response per line on stdout (ADR 0014). No socket
-- is ever opened for listening: the host talks to us through our stdin and stdout only.
-- Kept between requests: one Redis connection (reconnected on failure) and the bounded LRU.
local json = require("src.vendor.dkjson")
local cli = require("src.cli")
local cache = require("src.cache")
local deadline = require("src.deadline")
local output = require("src.output")
local redis = require("src.redis_client")
local log = require("src.log")

local M = {}

M.MAX_LINE = 64 * 1024
local MAX_ID = 128

local COMMANDS = { fetch = true, snapshot = true, convert = true, health = true }
local ALLOWED = {
   fetch = { id = true, command = true, symbols = true },
   snapshot = { id = true, command = true, symbols = true },
   convert = { id = true, command = true, from = true, to = true, amount = true },
   health = { id = true, command = true },
}

local function bad(detail)
   return nil, output.error_body("BAD_ARGS", detail)
end

-- Request line -> req (same shape as cli.parse), or nil, error body. Same rules as the CLI.
local function parse_request(t)
   if type(t.command) ~= "string" or not COMMANDS[t.command] then
      return bad("command must be one of fetch, snapshot, convert, health")
   end
   for k in pairs(t) do
      if not ALLOWED[t.command][k] then
         return bad("unknown field " .. (type(k) == "string" and k:sub(1, 32) or "?") .. " for " .. t.command)
      end
   end
   if t.command == "fetch" or t.command == "snapshot" then
      if type(t.symbols) ~= "table" then
         return bad("symbols must be an array of strings")
      end
      local symbols, _, detail = cli.validate_symbol_list(t.symbols)
      if not symbols then
         return bad(detail)
      end
      return { command = t.command, symbols = symbols }
   elseif t.command == "convert" then
      local from, _, d1 = cli.validate_symbol(t.from)
      if not from then return bad("from: " .. d1) end
      local to, _, d2 = cli.validate_symbol(t.to)
      if not to then return bad("to: " .. d2) end
      local amount, _, d3 = cli.validate_amount(t.amount)
      if not amount then return bad(d3) end
      return { command = "convert", from = from, to = to, amount = amount }
   end
   return { command = "health" }
end

-- One line -> response body (with id). Never raises.
local function handle(line, state)
   if #line > M.MAX_LINE then
      return output.error_body("BAD_ARGS", "request line longer than " .. M.MAX_LINE .. " bytes")
   end
   local ok, t = pcall(json.decode, line)
   if not ok or type(t) ~= "table" or t[1] ~= nil then
      return output.error_body("BAD_ARGS", "invalid JSON")
   end
   local id = t.id
   if id ~= nil and (type(id) ~= "string" or #id > MAX_ID) then
      return output.error_body("BAD_ARGS", "id must be a string of at most " .. MAX_ID .. " characters")
   end
   log.set_request(id)

   local req, err_body = parse_request(t)
   if not req then
      err_body.id = id
      return err_body, 2
   end

   local d = deadline.new(state.config.deadline_ms)
   local ctx = { config = state.config, deadline = d, log = log, cache = state.cache }
   -- Reuse the connection; create it on first use or after a failed connect.
   if not state.redis then
      state.redis = redis.from_config(state.config, d)
   end
   ctx.redis = state.redis

   log.info("invocation_start", { command = req.command, symbols = req.symbols })
   local run_ok, body, code = xpcall(function()
      return require("src.commands." .. req.command).run(req, ctx)
   end, debug.traceback)
   if not run_ok or type(body) ~= "table" then
      log.error("internal_error", { detail = tostring(body) })
      body, code = output.error_body("INTERNAL_ERROR",
         "unexpected internal error; see stderr logs for inv " .. log.invocation_id() .. " req " .. tostring(id)), 1
   end
   log.info("invocation_end", { exit_code = code, duration_ms = d:elapsed_ms(),
      cache = type(body.meta) == "table" and body.meta.cache or nil })
   body.id = id
   return body, code
end

function M.run(_, ctx)
   local cfg = ctx.config
   local state = { config = cfg, cache = cache.new(cfg.cache_max_entries, cfg.cache_max_bytes) }
   local requests = 0
   while true do
      local line = io.stdin:read("L")
      if line == nil then
         break -- EOF: clean exit
      end
      line = line:gsub("\r?\n$", "")
      if line:find("%S") then
         requests = requests + 1
         local ok, body = pcall(handle, line, state)
         if not ok then
            log.error("internal_error", { detail = tostring(body) })
            body = output.error_body("INTERNAL_ERROR", "unexpected internal error")
         end
         if body.id == nil then
            body.id = json.null -- always echo the id field, null when it couldn't be read
         end
         if not output.emit(body) then
            output.emit(output.error_body("INTERNAL_ERROR", "response could not be encoded"))
         end
         log.set_request(nil)
      end
   end
   local st = state.cache:stats()
   st.requests = requests
   log.info("daemon_end", st)
   if state.redis then state.redis:close() end
   return false, 0
end

return M
