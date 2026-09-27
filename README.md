# market — live crypto market ingest worker

A one-shot Lua 5.4 CLI that other services spawn many times per second: arguments in, **one JSON
object on stdout**, JSON-line logs on stderr, a meaningful exit code. It fetches live prices from a
public market API (CoinGecko by default), normalizes them to a versioned schema (`ticker.v1`) with
prices as exact decimal strings, and uses **Redis** so concurrent processes share one lock, one
rate limit and one set of last-good snapshots: 200 parallel `fetch` calls make one vendor call.
There is no HTTP server and no listening port anywhere.

- Design: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · decisions: [docs/adr/](docs/adr/README.md)
- Measured load: [docs/LOAD.md](docs/LOAD.md) · host example: [scripts/host_example.py](scripts/host_example.py)

## Quick start (Docker Compose)

Needs Docker with Compose. The repo is bind-mounted into the `app` container, which sets
`REDIS_HOST=redis`.

```bash
docker compose build                                           # Lua 5.4 + luarocks deps (once)
docker compose up -d redis                                     # start Redis
docker compose run --rm app lua market.lua fetch BTC           # one live fetch
docker compose run --rm app lua market.lua health              # Redis ping, last fetch, cooldown
docker compose run --rm app sh scripts/load.sh                 # 200 fetches, 50 in parallel
docker compose run --rm app busted                             # tests
```

On Docker Desktop for Windows/macOS, each process started from the bind mount pays ~70 ms of
file access; for load numbers that match a Linux host, run from a copy inside the container:
`docker compose run --rm app sh -c 'cp -r /app /tmp/app && cd /tmp/app && sh scripts/load.sh'`
(see [docs/LOAD.md](docs/LOAD.md)).

## Quick start (native Linux / WSL)

This is how a real host runs it: `lua market.lua ...` directly. (Verified step by step on a clean
Ubuntu 24.04 container on 2026-09-27; not yet on a physical WSL install.)

```bash
sudo apt install lua5.4 liblua5.4-dev luarocks build-essential libssl-dev
sudo update-alternatives --set lua-interpreter /usr/bin/lua5.4   # distro `lua` is 5.1
luarocks --lua-version=5.4 install --local --only-deps market-dev-1.rockspec
eval "$(luarocks --lua-version=5.4 path)"                        # --local rocks + ~/.luarocks/bin
docker compose up -d redis                                       # or any reachable Redis
export REDIS_HOST=127.0.0.1
lua market.lua fetch BTC
lua market.lua health
sh scripts/load.sh                                               # 200 fetches, 50 in parallel
busted                                                           # tests (need the compose Redis)
```

Use an IP for `REDIS_HOST` (or cap the resolver with `RES_OPTIONS="timeout:1 attempts:1"`):
name lookup is the one step luasocket cannot put a timeout on.

## Commands

```
lua market.lua fetch BTC,ETH,SOL                         live prices (cached for 5 s, shared by all processes)
lua market.lua snapshot --symbols BTC,ETH                cached prices only, never calls the vendor
lua market.lua convert --from BTC --to USDT --amount 1.5 exact conversion from cached prices
lua market.lua health                                    Redis ping, last fetch, vendor calls, cooldown
lua market.lua daemon                                    NDJSON requests on stdin, one response per line
```

Symbols are `A-Z0-9`, 1–15 characters, comma-separated (duplicates dropped), at most 50 per call.
Amounts are positive decimals, at most 30 integer digits and 18 decimals. Anything containing
`; | & $ \` ( ) < > \ ' "`, whitespace or control characters is rejected (`BAD_ARGS`, exit 2);
arguments never reach a shell.

## Spawn contract

| | |
|---|---|
| **argv** | `lua /path/to/market.lua <command> [args]` as an argument list, never through a shell |
| **cwd** | doesn't matter (see below) |
| **env** | the table below; only `REDIS_HOST` is required. Validated once at startup: any bad value → `BAD_CONFIG`, exit 2 |
| **stdout** | exactly **one** JSON object on one line (daemon: one object per input line). Nothing else is ever printed there, so the whole of stdout is the payload |
| **stderr** | logs, one JSON object per line (`ts`, `level`, `inv`, `event`, ...); never secrets. Pretty-print with `lua market.lua fetch BTC 2> >(jq -c .)` |
| **exit code** | `0` ok · `1` business/upstream error (JSON body still on stdout) · `2` bad arguments or configuration · `3` Redis unavailable |
| **time** | every run finishes within `DEADLINE_MS` (4 s); set the host's kill timeout above it |

**Working directory and `LUA_PATH`.** `market.lua` puts its own directory first on
`package.path` (from `arg[0]`), so `cd / && lua /opt/market/market.lua health` works without
setting anything. The equivalent by hand is `LUA_PATH="/opt/market/?.lua;/opt/market/?/init.lua;;"`
(the trailing `;;` keeps Lua's default path for the luarocks modules).

**Error codes** (stable): `BAD_ARGS`, `BAD_CONFIG`, `UNKNOWN_SYMBOL`, `SOURCE_UNAVAILABLE`,
`RATE_LIMITED`, `BAD_PAYLOAD`, `PRICE_UNAVAILABLE`, `REDIS_UNAVAILABLE`, `DEADLINE_EXCEEDED`,
`INTERNAL_ERROR`.

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `REDIS_HOST` | **required** | Redis host; there is no default host |
| `REDIS_PORT` / `REDIS_PASSWORD` | `6379` / unset | Redis port and optional password |
| `REDIS_TIMEOUT_MS` | `200` | connect/read timeout per Redis operation |
| `MARKET_SOURCE` | `coingecko` | `coingecko`, `binance` or `kraken` |
| `MARKET_QUOTE` | `USD` | quote currency (Binance has no USD pairs: it prices in USDT and says so) |
| `SOURCE_URL` | adapter's own | vendor base URL override (mocks and fixtures) |
| `SOURCE_TIMEOUT_MS` | `2000` | vendor HTTP timeout |
| `DEADLINE_MS` | `4000` | total budget per invocation; keep it below the host's kill timeout |
| `LOCK_TTL_MS` | `3000` | single-flight lock TTL; must satisfy `SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS` |
| `SNAPSHOT_FRESH_S` / `SNAPSHOT_KEEP_S` | `5` / `3600` | "fresh, don't refetch" window / last-good retention |
| `RATE_LIMIT_WINDOW_S` / `RATE_LIMIT_PER_WINDOW` | `10` / `5` | shared vendor-call cap |
| `MAX_CONCURRENT_UPSTREAM` | `1` | in-flight vendor calls per source (only `1` is accepted) |
| `CACHE_MAX_ENTRIES` / `CACHE_MAX_BYTES` | `256` / `1048576` | daemon in-process LRU bounds |
| `CONVERT_SCALE` | `8` | decimals of `convert` results (round half to even) |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

## Output examples

`fetch` (live, first call in the 5 s window; later calls say `"cache":"hit"` and `"http_ms":0`):

```json
{"ok":true,"schema":"ticker.v1","as_of_unix":1790528981,"source":"coingecko","items":[{"symbol":"BTC","quote":"USD","price":"84378","volume_24h":"21954198073.562046","change_24h_pct":"0.36808338666521584","as_of_unix":1790528981,"stale":false}],"errors":[],"meta":{"cache":"miss","partial":false,"redis_ms":3,"http_ms":593}}
```

`fetch BTC,FAKECOIN` is a partial success (exit 0): BTC in `items`,
`{"symbol":"FAKECOIN","code":"UNKNOWN_SYMBOL",...}` in `errors`, `"partial":true`.

`snapshot --symbols BTC,DOGE` with only BTC cached (exit 0; nothing cached at all → exit 1):

```json
{"ok":true,"schema":"ticker.v1","as_of_unix":1790527647,"source":"coingecko","items":[{"symbol":"BTC","quote":"USD","price":"67210.12","volume_24h":"12345.67","change_24h_pct":"-1.24","as_of_unix":1790527647,"stale":false}],"errors":[{"symbol":"DOGE","code":"PRICE_UNAVAILABLE","detail":"no cached price for DOGE"}],"meta":{"cache":"hit","partial":true,"redis_ms":1,"http_ms":0}}
```

`convert --from BTC --to USDT --amount 1.5` with BTC = 67210.12 USD and USDT = 1.00002813 USD cached:

```json
{"ok":true,"schema":"convert.v1","as_of_unix":1790528322,"stale":false,"source":"coingecko","from":"BTC","to":"USDT","amount":"1.5","result":"100812.34414876","rate":"67208.22943251","legs":[{"symbol":"BTC","quote":"USD","price":"67210.12","as_of_unix":1790528324,"stale":false},{"symbol":"USDT","quote":"USD","price":"1.00002813","as_of_unix":1790528322,"stale":false}],"meta":{"cache":"hit","redis_ms":1,"http_ms":0}}
```

`health` (exit 0; with Redis down the same body with `"ok":false` and `"redis":{"ok":false,...}`, exit 3):

```json
{"ok":true,"schema":"health.v1","as_of_unix":1790528983,"process":{"ok":true,"lua":"Lua 5.4","version":"0.1.0"},"redis":{"ok":true,"latency_ms":1},"source":{"name":"coingecko","last_fetch_unix":1790528981,"last_fetch_age_s":2,"vendor_calls":1,"cooldown_active":false}}
```

`daemon`: one request per stdin line, one response per stdout line, `id` echoed, EOF → exit 0.

```bash
printf '%s\n' '{"id":"1","command":"fetch","symbols":["BTC"]}' \
              '{"id":"2","command":"snapshot","symbols":["BTC"]}' | lua market.lua daemon
# {"id":"1","ok":true,...,"meta":{"cache":"miss",...}}
# {"id":"2","ok":true,...,"meta":{"cache":"memory",...}}     <- answered from the in-process LRU
```

## Where this differs from the brief's examples

- **Quote is `USD`, not `USDT`** ([ADR 0015](docs/adr/0015-usd-quote-with-cross-rate-conversion.md)):
  CoinGecko quotes in fiat. `convert --to USDT` works through USDT's own USD price.
- **Redis down fails closed** ([ADR 0009](docs/adr/0009-fail-closed-when-redis-unavailable.md)):
  exit 3 with `REDIS_UNAVAILABLE`. Without Redis, uncoordinated workers would stampede the vendor.
- **Partial success** ([ADR 0010](docs/adr/0010-partial-success-semantics.md)): unknown symbols and
  bad vendor rows go to `errors[]` with a reason, the rest are returned, exit 0.
- **Vendor failures exit 1 with last-good data attached**
  ([ADR 0011](docs/adr/0011-vendor-failure-returns-error-with-last-good-data.md)): `ok:false`,
  `SOURCE_UNAVAILABLE` / `RATE_LIMITED` / `BAD_PAYLOAD` / `DEADLINE_EXCEEDED`, and the body still
  carries every cached item, each marked `stale` when it is old.
- **Every item carries its own `as_of_unix` and `stale`**; the top-level `as_of_unix` is the oldest
  item's ([ADR 0003](docs/adr/0003-versioned-output-schema-ticker-v1.md)).

## Layout

```
market.lua          entrypoint: argv -> validate -> config -> command -> one JSON line -> exit code
src/                cli, config, output, log, deadline, decimal, normalize, redis_client, lock,
                    limiter, snapshot, cache, commands/, source/ (coingecko, binance, kraken)
tests/              busted specs, fixtures/, support/ (process runner, vendor stub)
scripts/            load.sh, host_example.py
docs/               ARCHITECTURE.md, LOAD.md, adr/, the assignment brief
```
