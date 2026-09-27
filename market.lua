-- Entrypoint: lua market.lua <command> [args]
-- Contract: one JSON object on stdout, JSON-line logs on stderr, exit code 0/1/2/3 (ADR 0002).

-- Put this file's directory first on package.path so require("src.x") works from any cwd,
-- without LUA_PATH. arg[0] is the script path exactly as the host passed it.
local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

-- No commands yet: every invocation is a usage error.
os.exit(2)
