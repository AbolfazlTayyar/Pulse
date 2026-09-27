-- Lua dependencies for the market worker. Used by the Docker image and by the native
-- Linux/WSL path:  luarocks install --local --only-deps market-dev-1.rockspec
rockspec_format = "3.0"
package = "market"
version = "dev-1"

source = {
   url = "git+https://github.com/AbolfazlTayyar/Pulse.git",
}

description = {
   summary = "One-shot Lua CLI worker that ingests live crypto market data, coordinated via Redis",
}

dependencies = {
   "lua >= 5.4, < 5.5",
   "luasocket >= 3.1",   -- TCP for the RESP client, HTTP to vendors
   "luasec >= 1.3",      -- HTTPS to vendors
   "busted >= 2.2",      -- test runner (dev dependency, kept here so --only-deps installs it)
}

-- Only the dependency list is used; market.lua runs from the checkout, nothing is installed.
build = {
   type = "none",
}
