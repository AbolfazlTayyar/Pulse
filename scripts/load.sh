#!/bin/sh
# Load test (brief: "Load and coalescing"). Spawns N one-shot `lua market.lua fetch` processes,
# P at a time, like a host would, and reports wall-clock percentiles, real vendor HTTP calls
# (mkt:stats:vendor_calls:{source} after - before), meta.cache counts and exit codes.
#
#   sh scripts/load.sh              200 runs, 50 parallel, BTC,ETH
#   sh scripts/load.sh 20 20        the brief's smaller run
#   sh scripts/load.sh 200 50 BTC   other symbols
#
# Needs REDIS_HOST (docker compose sets it). Run it inside one container
# (`docker compose run --rm app sh scripts/load.sh`) or natively, never as one
# `docker compose run` per invocation: container start-up would swamp the numbers (ADR 0005).
set -eu

N=${1:-200}
P=${2:-50}
SYMS=${3:-BTC,ETH}
cd "$(dirname "$0")/.."

: "${REDIS_HOST:?REDIS_HOST must be set}"

vendor_calls() {
   lua - <<'EOF'
package.path = "./?.lua;" .. package.path
local config = assert(require("src.config").load())
local r = assert(require("src.redis_client").from_config(config))
print(assert(require("src.snapshot").get_vendor_calls(r, config.market_source)))
EOF
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

before=$(vendor_calls)
start=$(date +%s%N)
# Each invocation records "<wall ms> <exit code>" next to its stdout.
seq 1 "$N" | xargs -P "$P" -I{} sh -c '
   t0=$(date +%s%N)
   lua market.lua fetch "$1" >"$2/out.{}" 2>/dev/null && code=0 || code=$?
   t1=$(date +%s%N)
   echo "$(( (t1 - t0) / 1000000 )) $code" >"$2/time.{}"
' sh "$SYMS" "$tmp"
total_ms=$(( ($(date +%s%N) - start) / 1000000 ))
after=$(vendor_calls)

lua - "$tmp" "$N" "$P" "$SYMS" "$(( after - before ))" "$total_ms" <<'EOF'
package.path = "./?.lua;" .. package.path
local json = require("src.vendor.dkjson")
local dir, n, p, syms, calls, total = arg[1], tonumber(arg[2]), arg[3], arg[4], arg[5], arg[6]
local times, caches, codes = {}, {}, {}
for i = 1, n do
   local tf = io.open(dir .. "/time." .. i)
   local ms, code = tf:read("n", "n")
   tf:close()
   times[#times + 1] = ms
   codes[code] = (codes[code] or 0) + 1
   local of = io.open(dir .. "/out." .. i)
   local body = json.decode(of:read("a") or "")
   of:close()
   local key = type(body) ~= "table" and "no-json"
      or (body.ok and body.meta and body.meta.cache)
      or ("error:" .. tostring(body.code))
   caches[key] = (caches[key] or 0) + 1
end
table.sort(times)
local function pct(q) return times[math.max(1, math.ceil(q * #times))] end
local function fmt(t)
   local keys, parts = {}, {}
   for k in pairs(t) do keys[#keys + 1] = tostring(k) end
   table.sort(keys)
   for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. (t[k] or t[tonumber(k)]) end
   return table.concat(parts, " ")
end
print(string.format("invocations: %d   parallel: %s   symbols: %s", n, p, syms))
print(string.format("wall-clock per invocation: p50 %d ms   p95 %d ms   max %d ms", pct(0.5), pct(0.95), times[#times]))
print(string.format("whole run: %d ms", total))
print(string.format("vendor HTTP calls: %s   (vs %d invocations)", calls, n))
print("meta.cache: " .. fmt(caches))
print("exit codes: " .. fmt(codes))
EOF
