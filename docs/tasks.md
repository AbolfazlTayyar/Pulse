# Tasks

The build plan for the market ingest worker, in the order it should be built. Each task has a
prompt you can paste into a fresh Claude Code session. Every prompt assumes the tasks above it are
done, and that [CLAUDE.md](../CLAUDE.md) and [docs/adr/](adr/README.md) are in force: decisions
there are not re-opened inside a task.

Status: ⬜ Not started · 🟨 In progress · ✅ Done

A task is **done** when its checkpoint has actually been run and passed, not when the code is
written.

| Phase | Tasks |
|---|---|
| A — Foundation | [A1](#project-skeleton--dev-environment-a1) · [A2](#string-preserving-json-a2) · [A3](#stdout-writer-and-stderr-logger-a3) · [A4](#configuration-a4) · [A5](#argument-parsing-and-entrypoint-a5) · [A6](#time-budget-a6) |
| B — Money math | [B1](#arbitrary-precision-decimals-b1) |
| C — Redis | [C1](#redis-client-c1) · [C2](#single-flight-lock-c2) · [C3](#rate-limit-and-429-cooldown-c3) · [C4](#snapshot-store-c4) |
| D — Market sources | [D1](#vendor-row-validation-d1) · [D2](#coingecko-adapter-and-source-registry-d2) · [D3](#binance-and-kraken-adapters-d3) |
| E — Commands | [E1](#snapshot-command-e1) · [E2](#health-command-e2) · [E3](#fetch--cache-hit-and-leader-path-e3) · [E4](#fetch--followers-and-coalescing-e4) · [E5](#fetch--vendor-failures-e5) · [E6](#convert-command-e6) · [E7](#in-process-lru-cache-e7) · [E8](#daemon-mode-e8) |
| F — Deliverables | [F1](#load-test-and-loadmd-f1) · [F2](#host-wrapper-example-f2) · [F3](#readme-f3) · [F4](#architecture-note-f4) · [F5](#final-review-against-the-brief-f5) |

---

## Phase A — Foundation

### Project skeleton & dev environment **[A1]**

✅ **Done**

**Description:** The empty house everything else is built in. One command gives you Lua 5.4,
its libraries and a Redis, on any machine. Nothing market-related works yet.

**Prompt:**
```
Create the project skeleton described in CLAUDE.md ("Architecture" and "Development commands")
and ADRs 0004, 0005 and 0016:

- Dockerfile: Lua 5.4, luarocks, luasocket, luasec, busted. The repo is bind-mounted, not copied,
  so edits show up without a rebuild.
- docker-compose.yml: an `app` service (sets REDIS_HOST=redis) and a `redis` service (official
  image, port 6379).
- market-dev-1.rockspec at the repo root listing the same Lua dependencies, for the native
  Linux/WSL path.
- market.lua: prepends its own directory to package.path so it runs from any cwd without
  LUA_PATH. For now it does nothing else and exits 2. Commands come in later tasks.
- Empty src/, src/commands/, src/source/, src/vendor/, tests/fixtures/, scripts/ folders as needed,
  and one trivial busted spec that proves the test runner works.
- .gitignore.

Don't implement any commands or modules yet. Verify the Docker path end to end; if WSL is
available, verify the native path too, otherwise say it wasn't checked.
```

**Checkpoint:** `docker compose build` succeeds. `docker compose run --rm app lua -v` shows
Lua 5.4. `docker compose run --rm app busted` passes. Running `lua /app/market.lua` from a
different directory inside the container doesn't fail with "module not found".

**Expected output:**
```
$ docker compose run --rm app lua -v
Lua 5.4.x  Copyright (C) 1994-20xx Lua.org, PUC-Rio

$ docker compose run --rm app busted
●
1 success / 0 failures / 0 errors / 0 pending
```
In short: you can run Lua and the tests with one command, and Redis is ready to use.

---

### String-preserving JSON **[A2]**

✅ **Done**

**Description:** Normal JSON libraries turn `84115.123456789012345` into a float and quietly
lose digits. This patched copy of dkjson keeps every number as the exact text the vendor sent,
so a price is never rounded by accident.

**Prompt:**
```
Vendor dkjson (pure Lua, MIT) into src/vendor/dkjson.lua and patch it as described in ADR 0007:
number tokens are decoded as their original text (Lua strings), not Lua numbers. Disable LPeg mode
so the patched path is always the one used. Keep the license header and add a short comment at
the top that explains the patch and where it is.

Encoding must still work for the rest of the project (tables, strings, booleans, integers,
arrays vs objects, and a way to encode JSON null).

Write busted specs in tests/ covering: big and long-fraction numbers survive byte-for-byte,
negative numbers and exponents come back as their original text, integers inside arrays, nested
objects, and that encode(decode(x)) keeps numeric text unchanged. Add a spec that fails if LPeg
mode gets switched back on.
```

**Checkpoint:** All specs pass in Docker. Decoding a CoinGecko-shaped payload gives prices as
strings identical to the raw bytes.

**Expected output:**
```lua
local t = json.decode('{"usd": 84115.123456789012345, "vol": 1e3}')
t.usd   --> "84115.123456789012345"   (a string, every digit kept)
t.vol   --> "1e3"                     (original text, not 1000.0)
```
In short: whatever number the vendor sends, you get back exactly the same characters.

---

### stdout writer and stderr logger **[A3]**

✅ **Done**

**Description:** Two tiny modules that decide where text goes. The result goes to stdout for the
calling program to parse. Logs go to stderr for humans and log tools. Keeping them apart is what
lets another program read our output safely.

**Prompt:**
```
Implement src/output.lua and src/log.lua per ADR 0002 and ADR 0019.

output.lua is the ONLY module that ever writes to stdout. It encodes one Lua table as one JSON
object on one line, writes it and flushes. It also has a helper to build the minimal error body
{ok=false, code=..., detail=...}.

log.lua writes one JSON object per line to stderr with ts (ISO 8601 UTC with milliseconds),
level, inv (random 8-hex invocation id, the same for the whole process), optional req (daemon
request id), event, plus event-specific fields. It filters by LOG_LEVEL (debug/info/warn/error,
default info). A failed write to stderr is swallowed and never fails the job. It must never log
secrets: add a guard so fields like password/auth are never written, even if a caller passes them.

Use the JSON encoder from src/vendor/dkjson.lua for both, so one log event is always exactly one
line. Add busted specs for both modules (capture the streams), and add a spec that greps src/ for
print( / io.write / io.stdout outside output.lua and fails if it finds any.
```

**Checkpoint:** Specs pass. With `LOG_LEVEL=warn`, `info` lines are not written. The "no stray
stdout writes" spec fails if you add a `print()` to another module, and passes again once removed.

**Expected output:**
```
output.emit({ ok = true })            → stdout: {"ok":true}
log.info("cache_hit", {symbols={"BTC"}})
  → stderr: {"ts":"2026-09-27T10:00:00.123Z","level":"info","inv":"a1b2c3d4","event":"cache_hit","symbols":["BTC"]}
log.info("x", {password="hunter2"})   → the password never appears in stderr
```
In short: results only ever appear on stdout, logs only ever on stderr, one line each.

---

### Configuration **[A4]**

✅ **Done**

**Description:** Reads all settings from environment variables once, at startup, and refuses to
run if anything is missing or doesn't make sense. There is no hidden default Redis address, so
the worker never quietly connects to the wrong place.

**Prompt:**
```
Implement src/config.lua per CLAUDE.md "Environment variables", ADR 0017 and ADR 0021
("Explicit configuration").

- Read every variable in the CLAUDE.md table once, apply the documented defaults, and return one
  immutable config table. Take the env lookup as a parameter (defaulting to os.getenv) so tests
  can pass a fake environment.
- REDIS_HOST has no default: unset or empty → error BAD_CONFIG.
- Numeric values must be positive integers; anything else → BAD_CONFIG naming the variable.
- Enforce SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS.
- MAX_CONCURRENT_UPSTREAM: only 1 is accepted; anything else → BAD_CONFIG with a message that
  points to ADR 0018.
- MARKET_SOURCE must be coingecko, binance or kraken. MARKET_QUOTE must look like a currency code.
- CACHE_MAX_ENTRIES / CACHE_MAX_BYTES must be positive integers (ADR 0014).
- Return (config) or (nil, code, detail); never raise. Never include REDIS_PASSWORD in any error
  text.

Busted specs: defaults with only REDIS_HOST set, each invalid case above, and the invariant
violations.
```

**Checkpoint:** Specs pass. Every invalid case returns `BAD_CONFIG` with a message that names the
bad variable. No spec output or error message contains the password.

**Expected output:**
```lua
config.load(fake_env{})                             --> nil, "BAD_CONFIG", "REDIS_HOST is required"
config.load(fake_env{REDIS_HOST="redis"})           --> { redis_port=6379, deadline_ms=4000, lock_ttl_ms=3000, ... }
config.load(fake_env{REDIS_HOST="redis", LOCK_TTL_MS="1000"})
                                                    --> nil, "BAD_CONFIG", "need SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS"
config.load(fake_env{REDIS_HOST="redis", MAX_CONCURRENT_UPSTREAM="4"})
                                                    --> nil, "BAD_CONFIG", "... only 1 is supported, see ADR 0018"
```
In short: forget `REDIS_HOST` or set a nonsense timeout and the worker refuses to start and tells
you which setting is wrong.

---

### Argument parsing and entrypoint **[A5]**

✅ **Done**

**Description:** The front door. It checks every argument against a strict allow-list before
anything else happens, so input like `BTC;rm -rf /` is rejected, and it guarantees that every run
ends with exactly one JSON object and a meaningful exit code.

**Prompt:**
```
Implement src/cli.lua and wire up market.lua, per CLAUDE.md "CLI contract" and "Coding rules",
ADR 0002 and ADR 0021 ("Fatal — caller").

cli.lua:
- Parses: fetch <SYMS>, snapshot --symbols <SYMS>, convert --from X --to Y --amount N, health,
  daemon.
- Symbols: comma-separated, each must match ^[A-Z0-9]{1,15}$, duplicates removed keeping order.
- Amount: positive decimal string, at most 30 integer digits and 18 decimals, no exponent, no sign,
  no spaces.
- Any argument containing ; | & $ ` ( ) < > \ quotes or whitespace-control chars → BAD_ARGS.
- Unknown command, missing or extra flags → BAD_ARGS with a detail that says what's wrong.
- Returns a request table or (nil, "BAD_ARGS", detail). Never raises.

market.lua:
- Order: parse argv → load config (A4) → dispatch to src/commands/<name>.lua → output.emit →
  os.exit(code). BAD_ARGS and BAD_CONFIG → exit 2 with the error body.
- Log invocation_start and invocation_end (exit_code, duration_ms).
- Commands that don't exist yet should produce a clear BAD_ARGS "not implemented yet".
- Wrap dispatch in a top-level pcall: an unexpected Lua error must never print a stack trace on
  stdout. Log it to stderr and print a JSON error body with exit 1. The stable error-code list has
  no code for internal errors — stop and ask me which code to use rather than inventing one.
- User input never reaches os.execute or io.popen (there should be none in the project at all).

Busted specs for cli.lua covering every rule above, including a table of injection attempts.
Also run market.lua for real in Docker for a few cases and check stdout and the exit code.
```

**Checkpoint:** Specs pass. For every bad input, stdout is a single JSON line and the exit code is
2. `grep -rn "os.execute\|io.popen" src market.lua` finds nothing.

**Expected output:**
```
$ lua market.lua fetch "BTC;rm -rf /"
{"ok":false,"code":"BAD_ARGS","detail":"symbol contains forbidden character ';'"}     (exit 2)

$ lua market.lua convert --from BTC --to USD --amount -5
{"ok":false,"code":"BAD_ARGS","detail":"amount must be a positive decimal"}            (exit 2)

$ lua market.lua fetch BTC,ETH,BTC
parsed as { command = "fetch", symbols = {"BTC","ETH"} }
```
In short: bad input is turned away at the door with exit code 2 and a JSON reason, and nothing
typed by a user can ever run as a shell command.

---

### Time budget **[A6]**

✅ **Done**

**Description:** A stopwatch for each run. The host may kill us after about 5 seconds, so every
wait and retry asks "do I still have time?" first. That way we finish and print JSON on our own
instead of being cut off halfway through.

**Prompt:**
```
Implement src/deadline.lua per CLAUDE.md ("Every network call has a timeout ... all waits respect
deadline.lua") and ADR 0021.

- deadline.new(ms) starts the budget using a millisecond clock (socket.gettime from luasocket).
- :remaining_ms(), :expired(), and :allows(ms) → true only if remaining > ms (used for the retry
  rules in ADR 0021).
- :sleep(ms) sleeps min(ms, remaining) and never past the deadline.
- :elapsed_ms() for duration_ms in logs and meta timings.

Create it in market.lua from config.deadline_ms and pass it to commands. Busted specs using a fake
clock (inject the clock function) so tests are fast and deterministic.
```

**Checkpoint:** Specs pass without real sleeping. `market.lua` passes one deadline object to
every command.

**Expected output:**
```lua
local d = deadline.new(4000)   -- after 1.2 s of work:
d:remaining_ms()   --> ~2800
d:allows(2000)     --> true    (enough time left for one more 2 s HTTP try)
d:allows(3000)     --> false   (not enough; skip the retry)
d:sleep(10000)     --> returns after ~2800 ms, never later
```
In short: every run has a hard time limit, and nothing waits or retries past it.

---

## Phase B — Money math

### Arbitrary-precision decimals **[B1]**

✅ **Done**

**Description:** A small calculator for money that works on digit strings, not floats. It can
add, multiply and divide numbers of any size exactly, and rounds only once at the very end.
Ordinary 64-bit integers overflow on normal `convert` inputs, so this is needed.

**Prompt:**
```
Implement src/decimal.lua per ADR 0007 and ADR 0020: arbitrary-precision integer + scale, with
the integer stored as base-10^7 limbs on Lua 5.4 integers.

- parse(str) → decimal or nil, err. Accepts optional leading "-", digits, optional fraction.
  Also accepts plain exponent notation from vendors ("1e3", "2.5E-4"), since the patched JSON
  keeps vendor text as-is. Rejects anything else.
- tostring / format(d, scale) with exactly `scale` decimals.
- add, sub, mul (exact), compare, is_positive.
- div(a, b, scale): long division with guard digits, then a single round-half-even to `scale`.
  Division by zero returns nil, err.
- Never call tonumber() on a money value and never go through a float.

Busted specs with reference values generated by Python's decimal module (write the values into
the spec, with a comment saying how they were produced). Include: 0.1 + 0.2, negative numbers,
half-even ties in both directions, 1 ÷ 3, huge values (30 integer digits × a price) that would
overflow 2^63, the ADR 0020 example, and inputs with leading/trailing zeros.
```

**Checkpoint:** All specs pass and match the Python reference values digit for digit, including
the rounding-tie cases.

**Expected output:**
```lua
decimal.add("0.1", "0.2")                          --> "0.3"        (a float would give 0.30000000000000004)
decimal.div("1", "3", 8)                           --> "0.33333333"
round_half_even("0.000000025", 8)                  --> "0.00000002" (tie → even digit)
round_half_even("0.000000035", 8)                  --> "0.00000004"
1.5 × 67210.12 ÷ 1.00002813, 8 decimals            --> "100812.34414876"
"123456789012345678901234567890" × "67210.12"      --> "8297545604334434560433443456035046.80" (no overflow)
```
In short: `0.1 + 0.2` is exactly `0.3`, and huge amounts never overflow or lose a cent.

---

## Phase C — Redis

### Redis client **[C1]**

✅ **Done**

**Description:** Our own small Redis connector. It sends a command and reads the answer, and it
gives up after 200 ms instead of hanging. If Redis is down it returns an error value, it never
crashes.

**Prompt:**
```
Implement src/redis_client.lua per ADR 0013, ADR 0009 and the Redis retry rules in ADR 0021.

- connect(host, port, timeout_ms, password?) over luasocket with settimeout on connect and on
  every read. AUTH when a password is set (never log it or the AUTH reply).
- call(...) encodes a RESP2 array and reads exactly one reply: simple string, error, integer,
  bulk string, null bulk, array. A missing key (null bulk) must be distinguishable from a failure.
- eval(script, keys, args).
- Every failure returns nil, err. Nothing raises across the module boundary.
- Retry support per ADR 0021: at most one retry after reconnecting, only for idempotent commands
  (caller marks them) or failures before the command was sent, and only if the deadline allows
  more than REDIS_TIMEOUT_MS. INCR, the rate-limit EVAL and SET NX are never retried.
- Log redis_error events (op, detail) without secrets.
- Record time spent in Redis so commands can report meta.redis_ms.

Add a small shared helper that turns a Redis failure into the REDIS_UNAVAILABLE body + exit 3
(ADR 0009) so every command does it the same way.

Integration specs against the compose Redis: PING, SET/GET, missing key, INCR, EVAL, an error
reply, a timeout against an unroutable address, and "Redis stopped" (connection refused).
```

**Checkpoint:** Specs pass against the compose Redis. With Redis stopped, the client returns an
error within about `REDIS_TIMEOUT_MS` and nothing hangs or raises.

**Expected output:**
```lua
r:call("PING")                 --> "PONG"
r:call("SET", "k", "v")        --> "OK"
r:call("GET", "k")             --> "v"
r:call("GET", "missing")       --> redis.null            (not an error)
-- Redis stopped:
r:call("GET", "k")             --> nil, "connection refused"   (returns in < 200 ms)
```
In short: talking to Redis is fast and always times out, and "Redis is down" becomes a normal
error value that ends in exit code 3.

---

### Single-flight lock **[C2]**

✅ **Done**

**Description:** A "talking stick" in Redis. Only the process holding it may call the market API,
and everyone else waits for its result. The stick expires on its own after 3 seconds, so a
process that gets killed can't hold it forever.

**Prompt:**
```
Implement src/lock.lua per ADR 0008 and ADR 0018.

- acquire(client, source, ttl_ms) → token (random, unguessable) when we got the lock,
  false when someone else holds it, nil, err on Redis failure.
  Uses SET mkt:lock:{source} <token> NX PX <ttl_ms>. Never retried (ADR 0021).
- release(client, source, token) → compare-and-delete in one EVAL: deletes only if the stored
  value is still our token. Returns true when released, false when the lock was no longer ours.
- remaining_ttl_ms(client, source) (PTTL) so the leader can check the HTTP retry rule in ADR 0021.
- Log lock_acquired / lock_busy / lock_released / lock_lost.
- The token must come from a real random source (e.g. /dev/urandom read with io.open), not
  math.random seeded with time, because many processes start in the same millisecond.

Integration specs against the compose Redis: two clients competing for the lock, release by the
holder, release after expiry when someone else took over (must not delete their lock), and expiry
without release ("process was killed").
```

**Checkpoint:** Specs pass, including the case where process A's lock expired, B took it, and A's
late release returns `false` and leaves B's lock alone.

**Expected output:**
```
A: acquire("coingecko") → "9f2c41e0..."   (A is the leader)
B: acquire("coingecko") → false           (busy, B waits)
A: release(token)       → true            (B can now take it)

A killed mid-fetch, never releases → after 3 s the key is gone → the next process becomes leader
```
In short: at most one process calls the market API at a time, and a crashed process can't block
everyone forever.

---

### Rate limit and 429 cooldown **[C3]**

✅ **Done**

**Description:** A shared counter in Redis that caps how often we call the market API: 5 calls per
10 seconds across all processes. It also has a "cooldown" switch: when the vendor says "too many
requests", everyone stops calling it for a while.

**Prompt:**
```
Implement src/limiter.lua per ADR 0012 and ADR 0011 (cooldown).

- take(client, source, window_s, limit) → allowed (bool), count. Key mkt:rl:{source}:{window}
  with window = floor(now / window_s). INCR + EXPIRE in one EVAL exactly as in ADR 0012. Never
  retried (ADR 0021). Log rate_limited (count, limit) when refused.
- set_cooldown(client, source, retry_after) → SET mkt:cooldown:{source} with TTL = Retry-After
  seconds, or 30 s when the header is missing or unparseable (ADR 0017). Log cooldown_set.
- cooldown_active(client, source) → bool, ttl_s. Log cooldown_active.
- Accept only the delta-seconds form of Retry-After; for the HTTP-date form, fall back to the
  default and note it in a comment.

Integration specs against the compose Redis with a small window so tests are quick: limit reached,
new window resets, key has a TTL, cooldown with and without Retry-After.
```

**Checkpoint:** Specs pass. After a test run, no `mkt:rl:*` key is left in Redis without a TTL.

**Expected output:**
```
limit 5 per 10 s:
take() ×5  → allowed, counts 1..5
take() #6  → refused (count 6, limit 5)      → RATE_LIMITED, no HTTP call
next 10 s window → allowed again

vendor answers 429 with "Retry-After: 12" → mkt:cooldown:coingecko exists for 12 s
vendor answers 429 with no header         → cooldown lasts 30 s
```
In short: no matter how many workers run, the vendor sees at most 5 calls per 10 seconds, and we
back off when it asks us to.

---

### Snapshot store **[C4]**

✅ **Done**

**Description:** Where the latest good price for each coin is kept in Redis, along with "when was
this fetched". It's the shared cache every process reads from, and what lets 200 runs share one
API call.

**Prompt:**
```
Implement src/snapshot.lua per ADR 0008, ADR 0003 (freshness fields) and CLAUDE.md "Redis keys".

- write(client, source, items, keep_s): one SET mkt:snapshot:{source}:{symbol} per item with
  EX keep_s. Each value is the normalized ticker JSON including as_of_unix. Only accept items that
  already passed validation (normalize.lua comes in D1, so assert the required fields exist here).
- read(client, source, symbols, now, fresh_s): one MGET. Returns, per symbol, the item with
  stale = (now - as_of_unix >= fresh_s), or "missing". A corrupt or unparseable stored value is
  treated as missing and logged, never a crash.
- set_last_fetch / get_last_fetch: mkt:meta:last_fetch:{source}.
- incr_vendor_calls / get_vendor_calls: mkt:stats:vendor_calls:{source} (no TTL, never retried).
- A helper that computes the top-level as_of_unix (oldest item) and the meta.cache value
  (hit / stale / mixed) from a set of items, so fetch, snapshot and convert all share one rule.

Integration specs against the compose Redis, using an injected "now" so freshness is tested
without sleeping.
```

**Checkpoint:** Specs pass. `redis-cli TTL mkt:snapshot:coingecko:BTC` shows about 3600 after a
write. A corrupt value in Redis is reported as missing, not as a crash.

**Expected output:**
```
write BTC with as_of_unix = 1000
read at now = 1003 → BTC, stale = false   (3 s old, fresh window is 5 s)
read at now = 1010 → BTC, stale = true    (10 s old)
read DOGE          → missing
SET mkt:snapshot:coingecko:ETH "garbage" → read ETH → missing (logged), no crash
```
In short: the last good price per coin lives in Redis for an hour, and every read tells you
whether it's fresh or stale.

---

## Phase D — Market sources

### Vendor row validation **[D1]**

✅ **Done**

**Description:** A gatekeeper for data coming from the market API. Each row must have all its
fields, real numbers and a price above zero, otherwise it's reported as an error and never saved.
One broken row can't stop the others.

**Prompt:**
```
Implement src/normalize.lua per ADR 0021 ("Vendor payload validation"), ADR 0010 and ADR 0003.

- validate_row(row) → item or nil, BAD_PAYLOAD detail. Required: symbol, quote, price, volume_24h,
  change_24h_pct. The three numbers must parse with decimal.lua (B1). price must be > 0.
  change_24h_pct may be negative. No sanity band against previous prices.
- build_items(rows, as_of_unix) → items[], errors[]. Each row is processed inside its own pcall,
  so a row that throws becomes one BAD_PAYLOAD error and the rest continue. Log symbol_error.
- Output items have exactly the ticker.v1 item fields, with prices as decimal strings in the
  vendor's original text (don't reformat them).

Busted specs: good row, each missing field, non-decimal price, price "0" and "-1", a row that is
not even a table, and a batch with one poison row among good ones.
```

**Checkpoint:** Specs pass. In the mixed batch, the good rows come out as items and the bad row
comes out as one `BAD_PAYLOAD` error.

**Expected output:**
```
{symbol="BTC", price="67210.12", volume_24h="12345.67", change_24h_pct="-1.24", ...}
    → item { symbol="BTC", quote="USD", price="67210.12", ..., as_of_unix=1726900000, stale=false }
{symbol="ETH", price="0", ...}      → error { symbol="ETH", code="BAD_PAYLOAD", detail="price must be > 0" }
{symbol="SOL", price="abc", ...}    → error { symbol="SOL", code="BAD_PAYLOAD", detail="price is not a decimal" }
[BTC ok, ETH bad, SOL ok]           → 2 items + 1 error, nothing crashes
```
In short: only clean data gets through, and one bad row costs one symbol, not the whole request.

---

### CoinGecko adapter and source registry **[D2]**

✅ **Done**

**Description:** The piece that talks to the real market API (CoinGecko), turns its JSON into our
standard shape, and reports what went wrong per coin. A registry picks the adapter from
`MARKET_SOURCE`, so other vendors can be plugged in later.

**Prompt:**
```
Implement src/source/init.lua (registry) and src/source/coingecko.lua per ADR 0006, the adapter
contract in CLAUDE.md, ADR 0007 and ADR 0021. Stay within the files in the CLAUDE.md
architecture tree: shared HTTP code goes in src/source/init.lua, not a new module.

- Registry: get(name) → adapter; unknown name is already rejected by config (A4).
- HTTP: luasocket/luasec with SOURCE_TIMEOUT_MS on connect and read. Base URL is an adapter
  constant, overridable via SOURCE_URL (log the URL at debug). Return the status, body, http_ms
  and, on 429, the Retry-After header. Classify failures as connect error / timeout / http status
  so the caller can apply the retry rules.
- Adapter contract: name, fetch(symbols, quote, timeout_ms) → rows, errors, info. Don't change
  the signature. The adapter itself does NOT retry: retries need the deadline and lock TTL, which
  only the fetch leader has (E3/E5). It just reports the failure kind clearly.
- CoinGecko: one /simple/price call for all symbols with vs_currencies = lower(MARKET_QUOTE),
  include_24hr_vol and include_24hr_change. Static symbol→id map (BTC→bitcoin, ETH→ethereum,
  SOL→solana, USDT→tether, USDC→usd-coin, BNB→binancecoin, XRP→ripple, ADA→cardano,
  DOGE→dogecoin, plus a few more). A symbol not in the map → UNKNOWN_SYMBOL without asking the
  vendor. A symbol missing from the response → UNKNOWN_SYMBOL. Rows go through normalize.lua (D1).
- Numbers stay as text from the patched dkjson (A2); never tonumber().
- ADR 0017 says to verify CoinGecko's current public rate limit. Check it and tell me if
  5 calls / 10 s is too high; don't change the default yourself.

Record one real CoinGecko response into tests/fixtures/coingecko/ (it's reachable from this
network). Busted specs that feed fixtures through a stubbed HTTP function: normal answer, unknown
symbol, missing field, 429 with Retry-After, 500, undecodable body. For timeout and connect errors,
point SOURCE_URL at an unroutable address (http://10.255.255.1) and a closed port
(http://127.0.0.1:1). Then one real call to CoinGecko to confirm it works.
```

**Checkpoint:** Specs pass. One real call to CoinGecko returns rows whose prices
match the raw response text exactly. You have reported what CoinGecko's current free-tier limit
actually is.

**Expected output:**
```lua
coingecko.fetch({"BTC","FAKECOIN"}, "USD", 2000)
--> rows   = { {symbol="BTC", quote="USD", price="84115", volume_24h="31914880000.5", change_24h_pct="-1.24"} }
--> errors = { {symbol="FAKECOIN", code="UNKNOWN_SYMBOL", detail="not supported by coingecko"} }
--> info   = { status=200, http_ms=410 }

vendor returns 429 "Retry-After: 12"          → rows={}, info={ kind="rate_limited", retry_after=12 }
SOURCE_URL=http://10.255.255.1 (no answer)   → rows={}, info={ kind="timeout", http_ms=2000 }
```
In short: ask for BTC and a made-up coin, and you get BTC's exact price plus a clear
"unknown symbol" for the other.

---

### Binance and Kraken adapters **[D3]**

✅ **Done**

**Description:** Two more plug-ins for other market APIs, to prove a new source can be added
without changing our output. They're tested with saved sample data, because both APIs are
blocked from this network.

**Prompt:**
```
Implement src/source/binance.lua and src/source/kraken.lua with the same contract as CoinGecko
(D2), and register them. Per ADR 0006, both are verified only with fixture JSON in
tests/fixtures/<source>/ via SOURCE_URL, because the live APIs are blocked from this network.
Write the fixtures from each vendor's public API documentation and say so in a comment.

- Binance: /api/v3/ticker/24hr with the symbols parameter for a batch. lastPrice, quoteVolume or
  volume (pick one and say which in a comment), priceChangePercent.
- Kraken: /0/public/Ticker; own symbol map (BTC→XBT etc.) and Kraken's odd response pair names.
  Last price from c[0], 24h volume from v[1]; change_24h_pct = (last − open) ÷ open × 100 computed
  with decimal.lua (B1), never floats. Choose and document the scale for that percentage.
- Quote currency: Binance has no USD pairs on its global API, only USDT and others. Do NOT silently
  treat USDT as USD. Stop and ask me how to map MARKET_QUOTE=USD for Binance before implementing
  that part.
- The output schema must not change at all: same ticker.v1 items as CoinGecko.

Busted specs for both adapters against fixtures: normal batch, unknown symbol, missing field,
and a check that the output matches exactly the same item shape as CoinGecko's.
```

**Checkpoint:** Specs pass. With `MARKET_SOURCE=kraken` and `SOURCE_URL` pointing at the Kraken
fixture, `lua market.lua fetch BTC` (once E3 exists) prints the same `ticker.v1` shape as
CoinGecko, with `"source": "kraken"`.

**Expected output:**
```
Kraken fixture: XXBTZUSD  c=["67210.12000","0.1"]  o="68055.00000"  v=["...","12345.67"]
→ { symbol="BTC", quote="USD", price="67210.12000", volume_24h="12345.67", change_24h_pct="-1.24" }
  (change = (67210.12 − 68055) ÷ 68055 × 100, computed with decimal.lua)
```
In short: switch `MARKET_SOURCE` and you get the same JSON shape from a different vendor.

---

## Phase E — Commands

### snapshot command **[E1]**

✅ **Done**

**Description:** "Show me the last known prices." It only reads from the Redis cache and never
calls the market API, so it's safe to run any number of times. Old prices are returned but
clearly marked stale.

**Prompt:**
```
Implement src/commands/snapshot.lua per ADR 0022 ("snapshot"), ADR 0003 and ADR 0010.

- lua market.lua snapshot --symbols BTC,ETH prints ticker.v1 from Redis only (C4). It never calls
  the vendor, never takes the lock, never touches the rate limit. (The daemon LRU layer is added
  in E8; leave a clear place for it.)
- Missing symbol → errors[] with PRICE_UNAVAILABLE; meta.partial true when there are both items
  and errors. All missing → ok false, code PRICE_UNAVAILABLE, exit 1.
- Old data → ok true, exit 0, stale true per item. meta.cache is hit / stale / mixed via the shared
  helper from C4. meta.http_ms is 0, meta.redis_ms is measured.
- Redis down → REDIS_UNAVAILABLE, exit 3 via the shared helper (C1).
- Log cache_hit / cache_miss and stale_served.

Integration specs that seed Redis directly (snapshot store from C4), then run the real
market.lua and check stdout JSON and the exit code. Include a spec that proves no vendor call is
made (mkt:stats:vendor_calls:{source} doesn't change).
```

**Checkpoint:** Every case in the prompt was run for real and returned the right body and exit
code. The vendor-call counter didn't change.

**Expected output:**
```
Redis has BTC (2 s old), nothing for DOGE:
$ lua market.lua snapshot --symbols BTC,DOGE
{"ok":true,"schema":"ticker.v1","source":"coingecko","items":[{"symbol":"BTC",...,"stale":false}],
 "errors":[{"symbol":"DOGE","code":"PRICE_UNAVAILABLE",...}],"meta":{"cache":"hit","partial":true,...}}   (exit 0)

BTC is 20 minutes old              → same body with "stale": true, still exit 0
nothing cached at all              → {"ok":false,"code":"PRICE_UNAVAILABLE",...}                        (exit 1)
Redis stopped                      → {"ok":false,"code":"REDIS_UNAVAILABLE",...}                        (exit 3)
```
In short: it shows whatever prices we already have and says how old they are, without ever
calling the market API.

---

### health command **[E2]**

✅ **Done**

**Description:** A real health check. It actually pings Redis and reports when we last got data
from the market API, how many API calls we've made, and whether we're in a cooldown. It never
fakes "all OK".

**Prompt:**
```
Implement src/commands/health.lua per ADR 0022 ("health") and the example body there.

- ok = result of a real Redis PING with REDIS_TIMEOUT_MS; redis.latency_ms measured.
- process block: ok, Lua version (_VERSION), project version.
- source block from mkt:meta:last_fetch, mkt:stats:vendor_calls and mkt:cooldown for the configured
  source; last_fetch_unix / last_fetch_age_s are null if never fetched.
- Redis down → still print the full health.v1 body with redis {ok=false, error=...} and null source
  values, then exit 3.
- Never calls the vendor, never touches the rate limit.

Integration specs: healthy with no fetch yet, healthy after seeding last_fetch and a cooldown,
Redis stopped.
```

**Checkpoint:** With Redis up, exit 0 and real values. With Redis stopped, a full `health.v1` body
and exit 3.

**Expected output:**
```
$ lua market.lua health
{"ok":true,"schema":"health.v1","as_of_unix":1726900100,
 "process":{"ok":true,"lua":"Lua 5.4","version":"0.1.0"},
 "redis":{"ok":true,"latency_ms":1},
 "source":{"name":"coingecko","last_fetch_unix":1726900000,"last_fetch_age_s":100,"vendor_calls":42,"cooldown_active":false}}   (exit 0)

Redis stopped → "ok":false, "redis":{"ok":false,"error":"connection refused"}, source values null   (exit 3)
```
In short: `health` tells the truth: Redis up or down, and when we last got fresh prices.

---

### fetch — cache hit and leader path **[E3]**

✅ **Done**

**Description:** The main command. If Redis already has fresh prices, print them. If not, take the
lock, call the market API once, save the results for everyone, and print them. This task covers
the "we are the one fetching" side.

**Prompt:**
```
Implement src/commands/fetch.lua for the cache-hit and leader paths, per the "fetch flow" in
CLAUDE.md, ADR 0008, ADR 0012, ADR 0018 and ADR 0021 (HTTP retry rules). Followers are E4 and
vendor failures are E5; leave clear hooks for both.

1. Read snapshots (C4). All requested symbols fresh → print, meta.cache "hit", http_ms 0.
2. Otherwise acquire the lock (C2). As leader, in this order:
   cooldown check (C3) → rate-limit take (C3) → incr vendor-call counter (C4) → adapter.fetch (D2)
   → validate (D1) → write snapshots + last_fetch (C4) → release the lock (C2) → print
   meta.cache "miss" with real http_ms and redis_ms.
   The leader fetches all requested valid symbols in one vendor call.
3. HTTP retry (ADR 0021): at most one, only for connect errors and 5xx, only if both the remaining
   deadline and the remaining lock TTL exceed SOURCE_TIMEOUT_MS. The retry increments the
   vendor-call counter too.
4. Unknown symbols and bad rows are partial success (ADR 0010): items + errors[], meta.partial,
   exit 0; exit 1 only when no items at all.
5. Release the lock in every path, including errors (but a lock we might hold after a Redis error
   is simply left to expire).
6. Logs: cache_hit/cache_miss, lock_acquired/lock_released/lock_lost, vendor_call (status, http_ms).

Integration specs against the compose Redis, with fixture data and a stubbed HTTP layer for
the vendor side, then a live check against real CoinGecko.
```

**Checkpoint:** Run for real: the first `fetch BTC,ETH` is a `miss`, an immediate second one is a
`hit` with `http_ms: 0`, and the vendor-call counter went up by exactly 1. `fetch BTC,FAKECOIN`
exits 0 with `meta.partial: true`.

**Expected output:**
```
$ lua market.lua fetch BTC,ETH        (empty cache)
{"ok":true,"schema":"ticker.v1","as_of_unix":1726900000,"source":"coingecko",
 "items":[{"symbol":"BTC","quote":"USD","price":"84115",...,"stale":false},{"symbol":"ETH",...}],
 "errors":[],"meta":{"cache":"miss","partial":false,"redis_ms":3,"http_ms":412}}          (exit 0)

$ lua market.lua fetch BTC,ETH        (1 s later)
same prices, "meta":{"cache":"hit",...,"http_ms":0}                                        (exit 0)

$ lua market.lua fetch BTC,FAKECOIN
BTC in items, FAKECOIN in errors as UNKNOWN_SYMBOL, "partial":true                          (exit 0)
```
In short: ask for BTC and ETH, and you get their live prices. Ask again within 5 seconds and they
come from the cache with no API call.

---

### fetch — followers and coalescing **[E4]**

✅ **Done**

**Description:** What happens to everyone who didn't get the lock: they wait briefly and read the
result the leader saved, instead of calling the API themselves. This is why 50 parallel runs cost
one API call, not 50.

**Prompt:**
```
Add the follower path to src/commands/fetch.lua per ADR 0008 ("Follower"), ADR 0011 and
ADR 0017 (poll interval).

- When the lock is busy, poll the snapshots every ~100 ms using deadline:sleep (A6). As soon as
  every requested symbol is fresh → print with meta.cache "coalesced".
- If the lock disappears while data is still not fresh (the leader failed or covered other
  symbols), try the lock again and become leader if we get it. Keep this bounded by the deadline;
  the rate limit and cooldown still cap vendor calls. Explain the choice in a comment.
- Deadline reached without fresh data → ok false, DEADLINE_EXCEEDED, exit 1, with last-good items
  attached as stale (ADR 0011). Log lock_busy (wait_ms) and deadline_exceeded (stage).
- Make sure a follower always finishes before DEADLINE_MS, leaving time to print.

Integration specs:
- Coalescing: from a clean cache, launch 20 parallel `lua market.lua fetch BTC,ETH` processes
  against live CoinGecko, then assert mkt:stats:vendor_calls:{source} went up by exactly 1,
  exactly one process printed "miss", and all others printed "coalesced" or "hit".
- Stuck leader: hold the lock by hand (redis-cli SET mkt:lock:coingecko someone-else PX 10000),
  then run fetch → it must return DEADLINE_EXCEEDED with exit 1 in under DEADLINE_MS.
```

**Checkpoint:** The 20-parallel spec passes repeatedly (run it at least 5 times) with exactly 1
vendor call each time. The stuck-leader spec returns `DEADLINE_EXCEEDED` before the deadline.

**Expected output:**
```
clean cache, 20 parallel `fetch BTC,ETH`:
  1 process    → "cache":"miss"
  19 processes → "cache":"coalesced"  (they waited ~0.4 s and read the leader's result)
  vendor-call counter: +1

lock held by someone else for 10 s, deadline 4 s:
  fetch → {"ok":false,"code":"DEADLINE_EXCEEDED",...,"items":[...last-good, "stale":true]}   (exit 1, after ~4 s)
```
In short: 20 identical requests at the same time → 1 API call, and everyone gets the answer.

---

### fetch — vendor failures **[E5]**

✅ **Done**

**Description:** What `fetch` does when the market API misbehaves: down, slow, "too many
requests", or garbage. It always answers `ok: false` with a clear code, still includes the last
good prices marked stale, and backs off when told to.

**Prompt:**
```
Complete the failure handling in src/commands/fetch.lua per ADR 0011, ADR 0021 (taxonomy) and
ADR 0012.

- Vendor timeout / connect error / 5xx (after the allowed retry) → SOURCE_UNAVAILABLE.
- Vendor 429 → set cooldown from Retry-After (default 30 s) → RATE_LIMITED.
- Cooldown active or shared rate limit exhausted → RATE_LIMITED without making the HTTP call
  (and without incrementing the vendor-call counter).
- Undecodable or wrong-shaped payload → BAD_PAYLOAD; nothing written to Redis; existing last-good
  untouched.
- In all of these: ok false, exit 1, and the body is still a full ticker.v1 document: fresh items as
  usual, last-good items with stale true, symbols with no data at all in errors[]
  (see the example in ADR 0011). Log stale_served, rate_limited, cooldown_set/cooldown_active.
- Unknown symbols alone remain partial success (ADR 0010), not a vendor failure.

Integration specs for every row of the ADR 0011 table: a stubbed HTTP layer for 500 / 429 /
undecodable bodies, and SOURCE_URL at an unroutable address (http://10.255.255.1) or a closed
port (http://127.0.0.1:1) for timeout and connect errors. Each spec asserts the body, the exit
code, the vendor-call counter, and that last-good snapshots are unchanged.
```

**Checkpoint:** Every failure case was run for real and gave the expected code, exit 1, and
last-good items marked stale. During a cooldown the vendor-call counter doesn't move.

**Expected output:**
```
vendor returns 500 twice        → {"ok":false,"code":"SOURCE_UNAVAILABLE","detail":"coingecko: HTTP 500",
                                   "items":[{"symbol":"BTC",...,"stale":true}],...}                   (exit 1, 2 HTTP calls)
vendor times out                → SOURCE_UNAVAILABLE                                                  (exit 1, 1 HTTP call, no retry)
vendor returns 429 Retry-After:12 → RATE_LIMITED; for the next 12 s every fetch → RATE_LIMITED with 0 HTTP calls
vendor returns "<html>oops"     → BAD_PAYLOAD; the BTC price saved earlier is still in Redis
```
In short: when the API breaks you always get `ok: false` and exit 1, plus the last good prices
clearly marked stale, and we never hammer a vendor that told us to slow down.

---

### convert command **[E6]**

✅ **Done**

**Description:** Converts an amount from one currency to another using cached prices, with exact
decimal math. It shows the prices it used so the result can be checked by hand. It never calls
the market API.

**Prompt:**
```
Implement src/commands/convert.lua per ADR 0020 (schema, computation table, failure behaviour)
and ADR 0015 (cross-rates).

- lua market.lua convert --from A --to B --amount X, cache only (snapshot store C4; LRU layer in E8).
- Cases A == B, B == quote, A == quote, and cross-rate exactly as the ADR 0020 table. All math in
  decimal.lua (B1). result and rate are each computed from the exact inputs with one final
  round-half-even to CONVERT_SCALE, and always printed with exactly CONVERT_SCALE decimals.
  Don't compute result as amount × rate (that rounds twice).
- legs[] with the prices used; top-level as_of_unix = oldest leg; stale = any leg stale.
- Missing price → PRICE_UNAVAILABLE, exit 1. Stale leg → still convert, stale true, exit 0.
  Redis down → exit 3. Never calls the vendor.

Integration specs that seed prices and check the exact strings below, plus a spec proving the
vendor-call counter didn't change.
```

**Checkpoint:** With BTC = `67210.12` and USDT = `1.00002813` seeded, the results match the values
below digit for digit.

**Expected output:**
```
cache: BTC = 67210.12 USD, USDT = 1.00002813 USD

$ lua market.lua convert --from BTC --to USDT --amount 1.5
{"ok":true,"schema":"convert.v1","from":"BTC","to":"USDT","amount":"1.5",
 "result":"100812.34414876","rate":"67208.22943251","stale":false,
 "legs":[{"symbol":"BTC","price":"67210.12",...},{"symbol":"USDT","price":"1.00002813",...}],...}   (exit 0)

--from BTC --to USD --amount 2      → "result":"134420.24000000", "rate":"67210.12000000"
--from BTC --to BTC --amount 1.5    → "result":"1.50000000", "rate":"1.00000000", "legs":[]
--from DOGE --to USD --amount 1     → {"ok":false,"code":"PRICE_UNAVAILABLE","detail":"no cached price for DOGE"}   (exit 1)
```
In short: 1.5 BTC → 100812.34414876 USDT, exact to 8 decimals, with the prices used shown
alongside.

---

### In-process LRU cache **[E7]**

✅ **Done**

**Description:** A small in-memory cache with a hard size limit: at most 256 entries and about
1 MiB. When full, it drops whatever was used least recently. It only helps in daemon mode, since
a one-shot process forgets everything when it exits.

**Prompt:**
```
Implement src/cache.lua per ADR 0014 ("In-process LRU").

- new(max_entries, max_bytes). Keys are "{source}:{symbol}", values are normalized ticker items.
- Size of an entry = length of its encoded JSON. Evict least-recently-used entries until both
  limits hold. An entry larger than max_bytes on its own is not cached.
- get(key, now, fresh_s) returns the item only while it is younger than fresh_s; get counts as a
  "use" for LRU order.
- O(1) get/put (hash map + doubly linked list), no globals.
- stats() → entries, bytes, hits, misses, evictions (useful in daemon logs).

Busted specs: eviction order, byte-limit eviction, oversized entry, freshness expiry, and a
stress spec (many random puts/gets) that checks both limits are never exceeded.
```

**Checkpoint:** Specs pass, including the stress spec that checks both limits after every
operation.

**Expected output:**
```
cache with max_entries = 2:
put A, put B, get A, put C   → B is evicted (A was used more recently)
put a 2 MiB item             → not stored (bigger than the 1 MiB cap)
get A 6 s after it was put   → miss (older than the 5 s fresh window)
```
In short: a memory cache that can never grow past its limits and always drops the
least-recently-used item first.

---

### Daemon mode **[E8]**

✅ **Done**

**Description:** A long-running mode that reads one JSON command per line from stdin and writes one
JSON answer per line. It keeps its Redis connection and the in-memory cache between commands,
which makes repeat requests faster. Still no network port.

**Prompt:**
```
Implement src/commands/daemon.lua per ADR 0014, ADR 0009 and ADR 0019 (req field).

- Read NDJSON from stdin line by line. Request: {"id": "...", "command": "fetch"|"snapshot"|
  "convert"|"health", ...args}. Validate with the same rules as the CLI (reuse cli.lua).
- Response: exactly the body the one-shot command would print, plus the echoed "id", one line per
  request, via output.lua.
- A malformed line → an error response for that line (BAD_ARGS, id echoed if it could be read);
  the daemon keeps running. EOF → clean exit 0.
- Each request gets its own deadline (DEADLINE_MS). Logs carry req = the request id.
- Reuse the Redis connection; reconnect on failure. With Redis down, the LRU (E7) may still answer
  snapshot for data younger than SNAPSHOT_FRESH_S; nothing ever calls the vendor without Redis
  (ADR 0009). Other commands get REDIS_UNAVAILABLE for that line and the daemon continues.
- Wire the LRU into fetch, snapshot and convert when running inside the daemon:
  meta.cache "memory" for LRU hits. In one-shot mode the LRU stays empty; say so in a comment.
- No sockets of any kind.

Integration specs that pipe several lines into `lua market.lua daemon` and check each output line,
including the LRU hit, the malformed line, and Redis being stopped mid-session.
```

**Checkpoint:** Piping the sample lines below gives one response per line with the ids echoed. The
repeated snapshot is served with `"cache":"memory"`. `ss -ltnp` (or equivalent) shows the daemon
listens on no port.

**Expected output:**
```
$ printf '%s\n' \
  '{"id":"1","command":"fetch","symbols":["BTC"]}' \
  '{"id":"2","command":"snapshot","symbols":["BTC"]}' \
  'not json' | lua market.lua daemon
{"id":"1","ok":true,"schema":"ticker.v1",...,"meta":{"cache":"miss",...}}
{"id":"2","ok":true,"schema":"ticker.v1",...,"meta":{"cache":"memory",...}}
{"id":null,"ok":false,"code":"BAD_ARGS","detail":"invalid JSON"}
(exit 0 on end of input)
```
In short: feed it one JSON command per line and you get one JSON answer per line; repeated
questions are answered from memory.

---

## Phase F — Deliverables

### Load test and LOAD.md **[F1]**

⬜ **Not started**

**Description:** Proof that the design holds up: run 200 fetches, 50 at a time, as the brief does,
and measure how long they took and how many real API calls happened. The goal is a handful of API
calls, not 200.

**Prompt:**
```
Write scripts/load.sh and docs/LOAD.md per the brief's "Load and coalescing" section, CLAUDE.md
"Deliverables checklist" and ADR 0008 ("Vendor-call counter").

scripts/load.sh (POSIX sh, runs inside the app container and natively):
- Reads mkt:stats:vendor_calls:{source} before and after.
- Runs seq 1 200 | xargs -P 50 -I{} lua market.lua fetch BTC,ETH, recording each invocation's
  wall-clock time, exit code and meta.cache.
- Prints p50 / p95 wall-clock, vendor calls (after − before) vs 200 invocations, a count per
  meta.cache value, and a count per exit code.
- Also supports the brief's smaller run (20 parallel).
- Measured inside one container, not one `docker compose run` per invocation (ADR 0005).

Run it for real against live CoinGecko, from a cold cache and from a warm cache. Then write
docs/LOAD.md: the command, the environment (machine, Docker or native), the real numbers, and the
caps table from ADR 0018 (concurrent calls per source, calls per window, HTTP timeout, retries,
429 backoff). Don't write numbers you didn't measure.
```

**Checkpoint:** The script ran against live CoinGecko. `docs/LOAD.md` contains the measured
numbers from that run, and the vendor-call count is far below 200.

**Expected output:**
```
$ docker compose run --rm app sh scripts/load.sh
invocations: 200   parallel: 50
wall-clock p50: 38 ms   p95: 520 ms          (example; real numbers go in LOAD.md)
vendor HTTP calls: 2   (vs 200 invocations)
meta.cache: hit=151 coalesced=47 miss=2
exit codes: 0=200
```
In short: 200 parallel requests result in a couple of real API calls, and the measured numbers are
written down.

---

### Host wrapper example **[F2]**

⬜ **Not started**

**Description:** A roughly 10-line Python script showing how another program would call our
worker: run it, read the JSON, check the exit code. It's the copy-paste example for other teams.

**Prompt:**
```
Write scripts/host_example.py (and optionally scripts/host_example.sh) per the brief's
"Callable from external services" section and CLAUDE.md "Deliverables checklist".

- About 10 lines, standard library only: subprocess.run([...lua, market.lua, "fetch", ...]) with
  an argument list (never shell=True), a timeout above DEADLINE_MS, capture stdout and stderr,
  json.loads(stdout), then print the exit code, ok, and each symbol's price.
- Pass the env through explicitly (REDIS_HOST required) and set cwd to show the worker doesn't
  depend on it.
- Handle the host-side cases in 2–3 lines: exit 3 → "Redis down", timeout → "killed".

Run it for real (natively or wherever Python is available) and show the output.
```

**Checkpoint:** The script ran for real and printed live prices. It uses no `shell=True`.

**Expected output:**
```
$ REDIS_HOST=127.0.0.1 python3 scripts/host_example.py BTC,ETH
exit=0 ok=True cache=hit
BTC 84115 USD
ETH 3120.55 USD
```
In short: a short, copyable example of calling the worker from Python and reading its answer.

---

### README **[F3]**

⬜ **Not started**

**Description:** The front page of the repo. It explains how to start Redis and run `fetch`,
`health` and the load test, both with Docker and natively, and it documents the exact contract a
calling program relies on.

**Prompt:**
```
Write README.md per CLAUDE.md "Deliverables checklist" and the brief.

- What this is in 2–3 sentences (a one-shot CLI worker; no HTTP; Redis for coordination).
- Quick start for BOTH paths (Docker Compose and native Linux/WSL): start Redis, run one fetch,
  run health, run the load command, run the tests.
- Spawn contract: argv for every command, every env var (link to the table), cwd (doesn't matter;
  explain the package.path trick and the LUA_PATH alternative), stdout = exactly one JSON object
  (daemon: one per line), stderr = JSON-line logs (recommend jq), exit codes 0/1/2/3, the stable
  error codes.
- Short output examples for fetch, snapshot, convert and health.
- Documented differences from the brief's example: quote is USD not USDT (ADR 0015), fail-closed
  Redis (ADR 0009), partial success (ADR 0010), vendor failures exit 1 with last-good attached
  (ADR 0011).
- Links to docs/ARCHITECTURE.md, docs/LOAD.md, docs/adr/, scripts/host_example.py.

Then follow the README yourself, top to bottom, on a clean checkout (docker compose down -v
first), and fix anything that doesn't work exactly as written.
```

**Checkpoint:** Every command in the README was run as written, from a clean state, and worked.
Anything that couldn't be checked (e.g. the native path without WSL) is marked as such.

**Expected output:** A README where a new engineer can copy three commands and see this:
```
$ docker compose up -d redis
$ docker compose run --rm app lua market.lua fetch BTC
{"ok":true,"schema":"ticker.v1",...,"items":[{"symbol":"BTC","price":"84115",...}],...}
$ docker compose run --rm app lua market.lua health
{"ok":true,"schema":"health.v1",...}
```
In short: someone who has never seen the project can run it in a few minutes.

---

### Architecture note **[F4]**

⬜ **Not started**

**Description:** The required 1–2 page explanation of how the system works and why, with one
diagram. It's the document reviewers read to judge the design, and it summarizes the ADRs rather
than repeating them.

**Prompt:**
```
Write docs/ARCHITECTURE.md (1–2 pages plus one simple diagram, Mermaid or ASCII) covering exactly
the six points the brief lists, in order:

1. Process model: one-shot CLI vs the optional daemon; the host owns concurrency, pooling and
   cancellation.
2. Data flow: argv → validate → Redis → maybe HTTP → normalize → print (the diagram), including
   the leader/follower lock flow.
3. Failure taxonomy: recoverable / retryable with a cap / fatal (summarize the ADR 0021 table).
4. Why results go to stdout, not an HTTP API: process lifecycle, timeouts, kill-on-cancel.
5. Memory vs Redis: what lives in the process (daemon LRU, bounds, eviction) and what is shared;
   say plainly that one-shot processes lose their memory on exit, so Redis is the real cache.
6. How to add a second market source without changing the print schema.

Also answer explicitly: what happens when the host kills Lua at 5 s mid-fetch (lock TTL, atomic
SET, nothing half-written), and why Redis-down is fail-closed. Link each point to its ADR(s)
instead of repeating their reasoning. Every statement must match the code as built; check it.
```

**Checkpoint:** The note is at most 2 pages plus the diagram, covers all six points and the
"killed at 5 s" question, and every claim was checked against the code.

**Expected output:** A reviewer reading only this page can answer: "How does one API call serve
200 processes?", "What if Redis dies?", "What if the process is killed mid-fetch?" and "How do I add
Kraken?", each in one or two sentences with a link to the ADR for details.

---

### Final review against the brief **[F5]**

⬜ **Not started**

**Description:** A last pass with the grading sheet in hand. Every requirement and every
"automatic fail" item is checked against the real repo with a command or test, not from memory.

**Prompt:**
```
Review the finished repo against docs/lua assignment.pdf and CLAUDE.md. Don't fix anything yet;
produce a report first.

For every requirement in the brief (commands, stdout/stderr/exit codes, env, functional
requirements 1–5, architecture note, constraints, README) and every row of "How we grade",
give: requirement → where it is met (file:line or doc section) → the command or test you just ran
as evidence → pass / fail.

Explicitly verify the automatic-fail items and the CLAUDE.md coding rules with real checks:
- no HTTP server or listening socket anywhere (grep for bind/listen/socket.bind/server; run the
  daemon and check no port is open);
- Redis is really used for lock, TTL snapshots and rate limit (show the keys during a run);
- one bad symbol never crashes: fetch BTC,FAKECOIN and a poison vendor row;
- no print()/io.write outside output.lua; no os.execute/io.popen; no globals (e.g. luac -l and
  look for SETTABUP _ENV, or luacheck if available); no tonumber() on money; no secrets in the
  repo; every network call has a timeout; no unbounded loops.
- The full busted suite passes; the load test result in docs/LOAD.md is still current.

End with a short list of gaps, most important first. Then stop and wait for me before fixing
anything.
```

**Checkpoint:** A report exists where every brief requirement has evidence from a command that
was actually run in this session. Gaps are listed, not silently fixed.

**Expected output:**
```
| Brief requirement                        | Where                         | Evidence                                   | Result |
|------------------------------------------|-------------------------------|--------------------------------------------|--------|
| `lua market.lua fetch BTC` → JSON stdout | market.lua, commands/fetch    | ran it: exit 0, one JSON line              | pass   |
| No HTTP server in Lua                    | —                             | grep bind/listen: 0 hits; daemon: no port  | pass   |
| 200 fetches ≠ 200 vendor calls           | docs/LOAD.md                  | load.sh: 2 vendor calls                    | pass   |
| ...                                      |                               |                                            |        |
Gaps: 1. ...  2. ...
```
In short: a pass/fail checklist of everything the graders look at, each with proof.
