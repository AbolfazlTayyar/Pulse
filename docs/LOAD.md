# Load and coalescing

Measured 2026-09-27 with [`scripts/load.sh`](../scripts/load.sh): `N` one-shot
`lua market.lua fetch BTC,ETH` processes, `P` at a time (`seq 1 N | xargs -P P`), like a host
spawning workers. The script reads `mkt:stats:vendor_calls:{source}` before and after, so
"vendor HTTP calls" is the number of real HTTP attempts, including failed ones
([ADR 0008](adr/0008-redis-single-flight-lock-and-snapshots.md)).

## Environment

| | |
|---|---|
| Machine | Windows 10 laptop, Intel Core i7-4720HQ @ 2.60 GHz; Docker Desktop 29.1.3, 8 vCPUs in the Linux VM |
| Runtime | Lua 5.4.4 in the `app` image (Debian bookworm), Redis 7.4.9 (`redis:7-alpine`), both from `docker-compose.yml` |
| Config | defaults: `SNAPSHOT_FRESH_S=5`, `LOCK_TTL_MS=3000`, `DEADLINE_MS=4000`, `SOURCE_TIMEOUT_MS=2000`, rate limit 5 / 10 s |
| Where | all invocations inside **one** container, as [ADR 0005](adr/0005-docker-compose-dev-environment.md) requires |

**Where the code lives matters on Docker Desktop for Windows.** From the bind mount (`/app` is
the Windows checkout), each process pays about 70 ms of file lookups before doing anything; a
single warm-cache `fetch` took ~80 ms from `/app` and 10–15 ms from a copy on the container's own
filesystem. The main tables below use the copy, which is what a Linux host sees:

```bash
docker compose up -d redis
docker compose run --rm app sh -c 'cp -r /app /tmp/app && cd /tmp/app && sh scripts/load.sh'
docker compose run --rm app sh -c 'cp -r /app /tmp/app && cd /tmp/app && sh scripts/load.sh 20 20'
```

`sh scripts/load.sh` without the copy works too; its numbers are in the last table.

## Results

### Live CoinGecko, answering normally

| Run | Invocations | p50 | p95 | Max | Vendor HTTP calls | `meta.cache` | Exit codes |
|---|---|---|---|---|---|---|---|
| cold cache, 200 × 50 | 200 | 32 ms | 735 ms | 751 ms | **1** | miss 1, coalesced 49, hit 150 | 0 ×200 |
| warm cache, 200 × 50 | 200 | 33 ms | 58 ms | 71 ms | **0** | hit 200 | 0 ×200 |
| 20 × 20, after the 5 s fresh window expired | 20 | 520 ms | 523 ms | 525 ms | **1** | miss 1, coalesced 19 | 0 ×20 |

Reading the cold row: the first wave of 50 processes finds no snapshot; one takes the lock and
calls CoinGecko (the `miss`), the other 49 poll Redis until its result lands (`coalesced`), and
the remaining 150 start after the snapshot exists (`hit`). p95 ≈ CoinGecko's latency, because
the first wave waits for it; everything after is a ~30 ms Redis read.

### Live CoinGecko, rate-limiting us

Earlier the same day CoinGecko answered **429** to every request from this network (the dev
machine's traffic leaves through a VPN whose exit IP CoinGecko rate-limits; keyless limits are
per IP and shared by everyone on it). These runs show the back-off path:

| Run | Invocations | p50 | p95 | Vendor HTTP calls | `meta.cache` / code | Exit codes |
|---|---|---|---|---|---|---|
| cold cache, 200 × 50 | 200 | 120 ms | 824 ms | **1** | `RATE_LIMITED` ×200 | 1 ×200 |
| right after, 200 × 50 | 200 | 32 ms | 534 ms | **0** | `RATE_LIMITED` ×200 | 1 ×200 |
| 20 × 20 | 20 | 24 ms | 219 ms | **0** | `RATE_LIMITED` ×20 | 1 ×20 |

The first leader got the 429 and set `mkt:cooldown:coingecko` from `Retry-After`; every later
process saw the cooldown and did not call the vendor at all: 420 invocations, 1 HTTP call.
Every response was `ok: false`, exit 1, per [ADR 0011](adr/0011-vendor-failure-returns-error-with-last-good-data.md).

### Healthy vendor (fixture, 400 ms simulated latency)

For a reproducible comparison with fixed vendor latency, the same script also ran against the recorded
CoinGecko fixture through the test stub (`LUA_INIT='require("tests.support.fixture_http")'`,
`SOURCE_URL=http://fixture/coingecko/simple_price.json`, `FIXTURE_DELAY_MS=400`). Everything
except the HTTP call itself is the real code path: Redis lock, snapshots, rate limit, counter.

| Run | Invocations | p50 | p95 | Max | Vendor HTTP calls | `meta.cache` | Exit codes |
|---|---|---|---|---|---|---|---|
| cold cache, 200 × 50 | 200 | 40 ms | 433 ms | 532 ms | **1** | miss 1, coalesced 49, hit 150 | 0 ×200 |
| warm cache, 200 × 50 | 200 | 31 ms | 49 ms | 57 ms | **0** | hit 200 | 0 ×200 |
| cold cache, 20 × 20 | 20 | 424 ms | 521 ms | 523 ms | **1** | miss 1, coalesced 19 | 0 ×20 |
| cold again after the 5 s fresh window expired | 200 | 34 ms | 434 ms | 443 ms | **1** | miss 1, coalesced 49, hit 150 | 0 ×200 |
| cold, from the bind mount (`/app`) | 200 | 572 ms | 1056 ms | 1147 ms | **1** | miss 1, coalesced 49, hit 150 | 0 ×200 |

The coalescing is also covered by `tests/cmd_fetch_spec.lua` ("20 parallel fetches make exactly
one vendor call"), which passed 6 runs out of 6.

## Caps

What bounds vendor traffic however many processes the host starts
([ADR 0018](adr/0018-upstream-concurrency-cap.md)):

| Bound | Value | Mechanism |
|---|---|---|
| Concurrent vendor calls per source | 1 | single-flight lock `mkt:lock:{source}` (`MAX_CONCURRENT_UPSTREAM` must be 1) |
| Vendor calls per window per source | 5 per 10 s | fixed-window counter `mkt:rl:{source}:{window}` |
| Refetch window | 5 s | fresh snapshots are served without the lock (`SNAPSHOT_FRESH_S`) |
| Duration of one vendor call | 2000 ms | `SOURCE_TIMEOUT_MS` on connect and every read |
| Retries per call | ≤ 1, connect errors and 5xx only, only if the deadline and lock TTL both allow | [ADR 0021](adr/0021-failure-taxonomy-and-retry-policy.md) |
| Back-off after 429 | `Retry-After` (1–3600 s) or 30 s | `mkt:cooldown:{source}` |
| Total time per invocation | 4000 ms | `DEADLINE_MS` |

CoinGecko publishes no number for keyless use ("IP-based rate limiting, shared across all users
on the same IP", docs as of 2026-06-15); the free Demo plan with an API key allows 100 calls/min.
5 per 10 s (30/min) is therefore not a guaranteed-safe keyless rate, and on a shared IP even far
fewer calls can get a 429, as the live runs above show. The cooldown keeps that from turning
into a stream of rejected calls.
