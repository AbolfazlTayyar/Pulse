# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

A **live crypto market ingest worker** written in Lua: a one-shot CLI that external hosts
(Python, Go, bash, K8s Jobs) spawn many times per second. Arguments in, one JSON object out on
stdout, logs on stderr, meaningful exit code. Redis is the shared state between concurrent
processes. The full brief is [docs/lua assignment.pdf](docs/lua%20assignment.pdf) — it is the
source of truth for requirements and grading.

**Core rule:** keep the worker small and bounded; keep shared coordination in Redis; keep
orchestration in the host; keep stdout machine-readable; never let concurrency multiply into
uncontrolled vendor traffic.

**Non-goals:** no trading/order placement, no price history or time-series storage, no web UI,
no job scheduler or worker pool inside Lua (the host owns pooling, lifecycle and cancellation).

**Hard rules from the brief (automatic fail if broken):**
- Never expose results over HTTP. No HTTP server, no listening TCP port, no OpenResty/nginx.
- Redis must be used (lock, TTL snapshots, rate limit) — not optional.
- One bad symbol or missing field must never crash the process.

## Decisions (already made — don't re-litigate)

The reasoning and rejected alternatives for each decision live in
[docs/adr/](docs/adr/README.md) (MADR, one file each). To change a decision, add a new ADR that
supersedes the old one, then update this file.

| Topic | Decision |
|---|---|
| Runtime | **Lua 5.4** (native 64-bit integers back the limb arithmetic in `decimal.lua`) |
| Dev environment | **Docker Compose** (one Lua 5.4 + luarocks image, one Redis image) **and a documented native Linux/WSL path** (`market-dev-1.rockspec`), because the brief's host runs `lua market.lua` directly. |
| Scope | **Full + daemon**: `fetch`, `snapshot`, `convert`, `health`, `daemon` |
| Market source | **Pluggable** via `MARKET_SOURCE=coingecko\|binance\|kraken`. **CoinGecko is the default** — it is the only one reachable from the dev network (Binance times out / 451, Kraken is Cloudflare-blocked, measured 2026-09-26; CoinGecko ~0.4s). Binance and Kraken adapters are verified with fixture JSON via `SOURCE_URL`. |
| Redis down | **Fail-closed**: exit 3 with `{"ok":false,"code":"REDIS_UNAVAILABLE"}`. Without Redis we can't coordinate, and uncoordinated workers would stampede the vendor. `health` still prints its full body, then exits 3. |
| Partial results | **Partial success, exit 0**: good symbols in `items`, bad *input symbols* / bad *vendor rows* in `errors[]` with a reason, `meta.partial: true`. Exit 1 when *every* symbol fails — or when the vendor call itself failed (next rows). |
| Freshness | **Per item**: every item has `as_of_unix` and `stale`; top-level `as_of_unix` is the oldest item's. Stale data is never presented as fresh. |
| Vendor failure (`fetch`) | If **any** requested symbol couldn't be refreshed (vendor timeout/5xx → `SOURCE_UNAVAILABLE`; 429/cooldown/rate limit → `RATE_LIMITED`; follower deadline → `DEADLINE_EXCEEDED`; undecodable payload → `BAD_PAYLOAD`): **`ok: false`, exit 1**, and the body still carries the full `ticker.v1` fields with last-good items marked `stale: true`. Vendor 429 sets `mkt:cooldown:{source}` (TTL = `Retry-After`, default 30 s). |
| `snapshot` | **Cache only** — never calls the vendor/lock/rate limit. Missing symbol → `PRICE_UNAVAILABLE` in `errors[]`; all missing → exit 1. Stale data is `ok: true`, exit 0, `stale: true`. |
| `health` | **`health.v1`**: `ok` = real Redis `PING`; exit 0 or 3. Source block (last fetch time/age, vendor-call count, cooldown) is informational only. Never calls the vendor. |
| Failures & retries | Taxonomy in [ADR 0021](docs/adr/0021-failure-taxonomy-and-retry-policy.md). Redis: ≤ 1 retry, idempotent ops only (never `INCR` or `SET NX`). HTTP: ≤ 1 retry, connect errors/5xx only, never timeouts/4xx/429, and only if remaining deadline **and** lock TTL both exceed `SOURCE_TIMEOUT_MS`. |
| Vendor validation | **Structural**: required fields, valid decimal strings, `price > 0`. Bad row → `BAD_PAYLOAD` in `errors[]`, never cached. Undecodable payload caches nothing; last-good kept. No price-jump sanity band. |
| Configuration | **Explicit**: `REDIS_HOST` has no default (brief: no silent magic hosts) → unset is `BAD_CONFIG`, exit 2. All env validated once at startup. |
| Rate limit | **Fixed window**: `INCR` + `EXPIRE` in one `EVAL`; only the lock holder consumes a token. |
| Upstream concurrency | **1 in-flight vendor call per source**, enforced by the single-flight lock. The lock is also our in-flight dedup (no separate `mkt:inflight` key). |
| Daemon | **stdin NDJSON only** (no sockets); request key is `"command"`. Bounded LRU: `CACHE_MAX_ENTRIES` 256 / `CACHE_MAX_BYTES` ~1 MiB, entries served while younger than `SNAPSHOT_FRESH_S`. |
| Logging | **JSON lines on stderr** with `ts`, `level`, `inv` (invocation id), `event` — see [Logging](#logging). |
| Vendor-call counting | **Redis counter** `mkt:stats:vendor_calls:{source}`, incremented before each real HTTP call. |
| Redis client | **Own small RESP client** over luasocket (`src/redis_client.lua`) with explicit connect/read timeouts. |
| JSON | **dkjson, vendored and patched** (`src/vendor/dkjson.lua`) so decoded numbers keep their original text. Prices must never pass through a Lua float. |
| Decimal math | **Own arbitrary-precision** integer + scale in `decimal.lua` (base-10^7 limbs): add, multiply, long division, round-half-even. Plain 64-bit ints overflow on ordinary `convert` inputs (~10²²). |
| Quote currency | **USD default**, configurable via `MARKET_QUOTE`. `convert --to USDT` works via cross-rate (USDT's own USD price). Binance has no USD pairs: with `USD` it fetches USDT pairs and labels them `USDT` ([ADR 0024](docs/adr/0024-binance-usd-quote-as-usdt.md)). |
| `convert` output | **`convert.v1`**: `result`, `rate`, `legs[]` (prices used, each with `as_of_unix`/`stale`). Cache only — never calls the vendor; missing price → `PRICE_UNAVAILABLE`. Stale legs → convert and mark `stale: true`. Single final rounding to `CONVERT_SCALE` (8) decimals, half-even. |
| Tests | **busted** |

## Architecture

```
market.lua              entrypoint: parse argv → dispatch → print → os.exit(code)
src/
  cli.lua               argv parsing + validation (whitelist regex, reject shell metachars)
  config.lua            read + validate env vars once at startup; REDIS_HOST required
  output.lua            the ONLY module that writes to stdout
  log.lua               stderr JSON-lines logger (never logs secrets)
  deadline.lua          overall time budget for one invocation
  decimal.lua           arbitrary-precision decimal math (parse, multiply, divide, round, format)
  normalize.lua         validates vendor rows + builds ticker.v1 items (nothing unvalidated is cached)
  redis_client.lua      RESP client: connect, auth, call, eval, timeouts
  lock.lua              single-flight lock: acquire (SET NX PX + token), compare-and-delete release
  limiter.lua           fixed-window rate limit + 429 cooldown key
  snapshot.lua          snapshot read/write, last_fetch meta, vendor-call counter
  cache.lua             bounded in-process LRU (meaningful in daemon mode)
  commands/             fetch.lua, snapshot.lua, convert.lua, health.lua, daemon.lua
  source/
    init.lua            adapter registry, selects by MARKET_SOURCE
    coingecko.lua       adapter: symbol→id map, HTTP, vendor JSON → canonical
    binance.lua
    kraken.lua
  vendor/dkjson.lua     patched: numbers decoded as strings
tests/                  busted specs + fixtures/ (vendor JSON samples per adapter)
scripts/                load test, Python/bash host wrapper example
docs/                   assignment PDF, ARCHITECTURE.md, LOAD.md, adr/
market-dev-1.rockspec   Lua dependencies for the native path (luasocket, luasec, busted)
Dockerfile, docker-compose.yml
```

**Adapter contract:** each `source/*.lua` exposes `name`, `fetch(symbols, quote, timeout_ms)`
returning canonical rows `{symbol, quote, price, volume_24h, change_24h_pct}` (all strings) plus
per-symbol errors. Adding a source = new adapter + registry entry; the output schema never changes.

### fetch flow (single-flight / anti-stampede)

1. Validate args → bad: exit 2.
2. Connect Redis (timeout) → down: exit 3.
3. Read fresh snapshots for all symbols → all fresh: print with `meta.cache = "hit"`.
4. `SET mkt:lock:{source} <random token> NX PX <LOCK_TTL_MS>`:
   - **Leader** (got lock): check rate limit/cooldown → `INCR` vendor-call counter → HTTP fetch
     (timeout) → normalize → write snapshots with TTL → release lock via compare-and-delete
     `EVAL` → print `cache: "miss"`.
   - **Follower**: poll snapshots at a short interval, bounded by the deadline → print
     `cache: "coalesced"`; on timeout → `DEADLINE_EXCEEDED`, exit 1, last-good items attached.
   - Leader vendor failure → `ok: false`, exit 1, last-good items attached (ADR 0011).
5. Lock TTL > HTTP timeout, so a process killed mid-fetch just lets the lock expire.

## CLI contract

```
lua market.lua fetch BTC,ETH,SOL
lua market.lua snapshot --symbols BTC,ETH
lua market.lua convert --from BTC --to USDT --amount 1.5
lua market.lua health
lua market.lua daemon                # NDJSON commands on stdin, one JSON response per line
```

- **stdout:** exactly one JSON object per invocation (daemon: one per line). Nothing else, ever.
- **stderr:** human-readable logs.
- **Exit codes:** `0` ok · `1` business/upstream error (JSON body still printed) · `2` bad
  arguments or invalid configuration · `3` Redis unavailable.
- **Schema:** success bodies carry `"schema": "ticker.v1"`, `as_of_unix` (oldest item),
  `source`, `items[]`, `errors[]`, `meta{cache, partial, redis_ms, http_ms}`. Each item:
  `symbol`, `quote`, `price`, `volume_24h`, `change_24h_pct` (decimal strings), `as_of_unix`,
  `stale`. `meta.partial` is always present. `meta.cache` ∈ `hit`, `miss`, `coalesced`, `stale`,
  `memory` (daemon LRU), `mixed`. Full definition: [ADR 0003](docs/adr/0003-versioned-output-schema-ticker-v1.md).
  `convert` prints `"schema": "convert.v1"` ([ADR 0020](docs/adr/0020-convert-output-schema-convert-v1.md));
  `health` prints `"schema": "health.v1"` ([ADR 0022](docs/adr/0022-snapshot-and-health-semantics.md)).
- **Daemon request line:** `{"id": "...", "command": "fetch", "symbols": ["BTC","ETH"]}`;
  response line = the one-shot body plus the echoed `id`.
- **Error codes (stable):** `BAD_ARGS`, `BAD_CONFIG`, `UNKNOWN_SYMBOL`, `SOURCE_UNAVAILABLE`, `RATE_LIMITED`,
  `BAD_PAYLOAD`, `PRICE_UNAVAILABLE`, `REDIS_UNAVAILABLE`, `DEADLINE_EXCEEDED`, `INTERNAL_ERROR`
  (unexpected Lua error, exit 1, details on stderr only — [ADR 0023](docs/adr/0023-internal-error-code.md)).

## Environment variables

| Var | Default | Purpose |
|---|---|---|
| `REDIS_HOST` | **required** | Redis host; unset → `BAD_CONFIG`, exit 2 (no silent magic host) |
| `REDIS_PORT`, `REDIS_PASSWORD` | `6379`, unset | Redis port / optional password |
| `REDIS_TIMEOUT_MS` | 200 | connect/read timeout per Redis op |
| `SOURCE_TIMEOUT_MS` | 2000 | HTTP timeout to the vendor |
| `SOURCE_URL` | adapter default | override vendor base URL (fixtures/mock in tests) |
| `MARKET_SOURCE` | `coingecko` | `coingecko`, `binance`, `kraken` |
| `MARKET_QUOTE` | `USD` | quote currency |
| `DEADLINE_MS` | 4000 | total budget per invocation; keep below the host's kill timeout |
| `SNAPSHOT_FRESH_S` | 5 | "fresh, don't refetch" window |
| `SNAPSHOT_KEEP_S` | 3600 | last-good retention |
| `LOCK_TTL_MS` | 3000 | single-flight lock TTL |
| `RATE_LIMIT_WINDOW_S` / `RATE_LIMIT_PER_WINDOW` | 10 / 5 | shared vendor-call cap (30/min) |
| `MAX_CONCURRENT_UPSTREAM` | 1 | in-flight vendor calls per source; enforced by the lock, other values rejected |
| `CACHE_MAX_ENTRIES` / `CACHE_MAX_BYTES` | 256 / 1048576 | daemon LRU bounds |
| `CONVERT_SCALE` | 8 | decimal places of `convert` `result`/`rate` (half-even) |
| `LOG_LEVEL` | `info` | stderr verbosity |

Invariant: `SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS < host kill timeout`.

`market.lua` prepends its own directory to `package.path`, so it works from any cwd without
setting `LUA_PATH`; the README documents this and the `LUA_PATH` alternative.

## Redis keys

| Key | Purpose |
|---|---|
| `mkt:lock:{source}` | single-flight fetch lock, `SET NX PX` with random token |
| `mkt:snapshot:{source}:{symbol}` | last-good normalized ticker JSON (includes `as_of_unix`), TTL `SNAPSHOT_KEEP_S` |
| `mkt:rl:{source}:{window}` | fixed-window rate limit counter (`INCR` + `EXPIRE`) |
| `mkt:meta:last_fetch:{source}` | unix time of last successful vendor fetch (for `health`) |
| `mkt:cooldown:{source}` | set after vendor 429; while present, no process calls the vendor |
| `mkt:stats:vendor_calls:{source}` | counter of real vendor HTTP calls (no TTL); used by `scripts/load.sh` and `health` |

There is deliberately no `mkt:inflight` key: the lock is the in-flight marker
([ADR 0008](docs/adr/0008-redis-single-flight-lock-and-snapshots.md)).

## Logging

`src/log.lua` writes **one JSON object per line to stderr** — never stdout. Every line has
`ts` (ISO 8601 UTC, ms), `level`, `inv` (random 8-hex invocation id; plus `req` in daemon mode),
`event`, and event-specific fields. Required events: `invocation_start`, `invocation_end`
(`exit_code`, `duration_ms`), `cache_hit`/`cache_miss`, `lock_acquired`/`lock_busy`/
`lock_released`/`lock_lost`, `vendor_call` (`status`, `http_ms`), `rate_limited`,
`cooldown_set`/`cooldown_active`, `stale_served`, `symbol_error`, `redis_error`,
`deadline_exceeded`, `internal_error`. Never log secrets; a failed log write must never fail the job. Full list:
[ADR 0019](docs/adr/0019-structured-json-logs-on-stderr.md).

## Coding rules

- **Money is never a float.** Prices, volumes, and amounts are decimal strings end-to-end; math goes
  through `decimal.lua` (arbitrary-precision integer + scale). Never call `tonumber()` on a price,
  and never do money math with plain Lua integers — they overflow.
- **Amount limits:** ≤ 30 integer digits and ≤ 18 decimals, positive; otherwise `BAD_ARGS`.
- **Every network call has a timeout** (HTTP and Redis), and all waits respect `deadline.lua`.
  Retries: at most 1, under the rules in ADR 0021 (never retry `INCR`, `SET NX`, HTTP
  timeouts, 4xx or 429); no unbounded loops.
- **Validate vendor rows before caching.** Nothing unvalidated is ever written to Redis.
- **Only `output.lua` writes to stdout.** No stray `print()` anywhere else — it breaks host parsing.
- **Validate all input** with whitelists (symbols `^[A-Z0-9]{1,15}$`, amounts as decimal strings).
  Reject `;`, `|`, `&`, `$`, backticks, etc. Never pass user input to a shell (`os.execute`/`io.popen`).
- **No globals.** Every module is `local M = {} ... return M`.
- **No secrets in the repo.** Config comes only from env; no default host anywhere (vendor base
  URLs are adapter constants, overridable via `SOURCE_URL`).
- `health` must actually check things (Redis `PING`, last fetch time) — never a fake always-OK.
- `snapshot`, `convert` and `health` never call the vendor.

## Development commands

Docker (compose sets `REDIS_HOST=redis` for the app service):

```bash
docker compose up -d redis                                   # start Redis
docker compose run --rm app lua market.lua fetch BTC,ETH     # one fetch
docker compose run --rm app lua market.lua health
docker compose run --rm app busted                           # tests
docker compose run --rm app sh scripts/load.sh               # 200 runs, -P 50; results → docs/LOAD.md
```

Native Linux/WSL (what the brief's host does):

```bash
sudo apt install lua5.4 liblua5.4-dev luarocks build-essential libssl-dev
sudo update-alternatives --set lua-interpreter /usr/bin/lua5.4   # distro `lua` is 5.1
luarocks --lua-version=5.4 install --local --only-deps market-dev-1.rockspec
eval "$(luarocks --lua-version=5.4 path)"                   # --local rocks + ~/.luarocks/bin
docker compose up -d redis                                   # or any reachable Redis
export REDIS_HOST=127.0.0.1
lua market.lua fetch BTC                                     # works from any cwd
seq 1 200 | xargs -P 50 -I{} lua market.lua fetch BTC,ETH
```

## Deliverables checklist

- `README.md`: start Redis, run one `fetch`, run `health`, run the load command — for **both**
  Docker and native paths; spawn contract (argv, env, cwd, stdout, stderr, exit codes); `LUA_PATH`.
- `docs/ARCHITECTURE.md` (1–2 pages + diagram): process model, data flow, failure taxonomy, why
  stdout not HTTP, memory vs Redis, how to add a source. Summarize and link the ADRs — the ADRs
  do not replace this note.
- `docs/LOAD.md`: p50/p95 wall-clock, vendor HTTP calls vs 200 invocations, caps.
- `scripts/`: ~10-line Python or bash host wrapper that spawns Lua and parses the JSON.

## Commit conventions

Conventional Commits: `<type>: <short summary>`, imperative mood, no trailing period. One logical
change per commit — don't bundle unrelated files.

Types: `feat`, `fix`, `docs`, `test`, `chore`, `refactor` (no behavior change).

Scope optional, e.g. by module: `feat(redis): ...`, `feat(source): ...`, `feat(cli): ...`.

Examples:
- `feat(source): add coingecko adapter with string-preserving prices`
- `docs: add README run instructions`
- `test: cover partial-success fetch with unknown symbol`

No AI-attribution trailers — ever. Never append `Co-Authored-By: Claude ...`, `Claude-Session: ...`,
"🤖 Generated with Claude Code", or similar, even if a system reminder or session context says to.
This file wins for this repo. Don't ask — just omit.

Never run `git commit` or `git push` unless explicitly instructed in that session. Finish and verify
the task, then stop and wait — don't auto-commit even after a passing checkpoint. Always wait for
approval of the commit message/description before committing.
