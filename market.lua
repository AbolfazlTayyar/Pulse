-- Entrypoint: lua market.lua <command> [args]
-- Contract: one JSON object on stdout, JSON-line logs on stderr, exit code 0/1/2/3 (ADR 0002).

-- Put this file's directory first on package.path so require("src.x") works from any cwd,
-- without LUA_PATH. arg[0] is the script path exactly as the host passed it.
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

-- The time budget counts from process start, not from when config was loaded.
local deadline = require("src.deadline")
local started_ms = deadline.now_ms()

local output = require("src.output")
local log = require("src.log")
local cli = require("src.cli")
local config = require("src.config")

local function internal_error_body()
   return output.error_body("INTERNAL_ERROR",
      "unexpected internal error; see stderr logs for inv " .. log.invocation_id())
end

-- Command modules live in src/commands/<name>.lua and expose run(req, ctx) -> body, exit_code,
-- where ctx = { config, deadline, log }. Every command gets the one deadline of this process.
-- A command that writes its own output (daemon) returns false as the body.
local function load_command(name)
   local modname = "src.commands." .. name
   if not package.searchpath(modname, package.path) then
      return nil
   end
   return require(modname)
end

local function run(argv)
   local req, code, detail = cli.parse(argv)
   log.info("invocation_start", { command = req and req.command, symbols = req and req.symbols })
   if not req then
      return output.error_body(code, detail), 2
   end

   local cfg
   cfg, code, detail = config.load()
   if not cfg then
      return output.error_body(code, detail), 2
   end
   log.set_level(cfg.log_level)

   local command = load_command(req.command)
   if not command then
      return output.error_body("BAD_ARGS", req.command .. " is not implemented yet"), 2
   end
   local d = deadline.new(cfg.deadline_ms, { start = started_ms })
   local body, exit_code = command.run(req, { config = cfg, deadline = d, log = log })
   return body, exit_code
end

local argv = {}
for i = 1, #arg do argv[i] = arg[i] end

local ok, body, exit_code = xpcall(run, debug.traceback, argv)
if not ok then
   log.error("internal_error", { detail = tostring(body) })
   body, exit_code = internal_error_body(), 1
elseif (body ~= false and type(body) ~= "table") or math.type(exit_code) ~= "integer" then
   log.error("internal_error", { detail = "command returned no body or no integer exit code" })
   body, exit_code = internal_error_body(), 1
end

-- body == false: the command wrote its own lines (daemon: one response per request line).
local written, err = true, nil
if body ~= false then
   written, err = output.emit(body)
end
if not written then
   log.error("internal_error", { detail = err })
   output.emit(internal_error_body())
   exit_code = 1
end

log.info("invocation_end", {
   exit_code = exit_code,
   duration_ms = math.floor(deadline.now_ms() - started_ms),
   cache = type(body) == "table" and type(body.meta) == "table" and body.meta.cache or nil,
})
os.exit(exit_code)
