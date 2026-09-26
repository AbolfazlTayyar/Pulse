# 0017 — Default tuning values ("balanced" profile)

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

Timeouts, TTLs and limits must be bounded (brief: unbounded retries fail review) and must
satisfy the lock invariant from [0008](0008-redis-single-flight-lock-and-snapshots.md):
`SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS < host kill timeout`.

## Considered Options

1. Balanced — moderate freshness, low vendor load
2. Aggressive freshness — 1 s fresh window, higher 429 risk
3. Conservative — 15 s fresh window, minimal vendor load

## Decision Outcome

Chosen option: **1 — balanced**. All values are env-overridable.

| Env var | Default | Why |
|---|---|---|
| `SNAPSHOT_FRESH_S` | 5 | At most ~12 vendor calls/min per source from the lock alone |
| `SNAPSHOT_KEEP_S` | 3600 | Last-good available for an hour of vendor trouble |
| `SOURCE_TIMEOUT_MS` | 2000 | CoinGecko measured ~0.4 s typical, ~1.1 s cold |
| `REDIS_TIMEOUT_MS` | 200 | Local Redis answers in < 5 ms; fail fast |
| `LOCK_TTL_MS` | 3000 | > HTTP timeout, so a live leader never loses its lock |
| `DEADLINE_MS` | 4000 | Below a typical 5 s host kill timeout |
| `RATE_LIMIT_WINDOW_S` | 10 | |
| `RATE_LIMIT_PER_WINDOW` | 5 | = 30 calls/min |
| `MAX_CONCURRENT_UPSTREAM` | 1 | Enforced by the per-source lock; only `1` is accepted ([0018](0018-upstream-concurrency-cap.md)) |
| `CACHE_MAX_ENTRIES` | 256 | Daemon LRU entry cap ([0014](0014-daemon-over-stdin-ndjson-with-in-process-lru.md)) |
| `CACHE_MAX_BYTES` | 1048576 | Daemon LRU size cap (~1 MiB) |
| `CONVERT_SCALE` | 8 | Decimal places of `convert` output, half-even ([0020](0020-convert-output-schema-convert-v1.md)) |
| 429 cooldown default | 30 s | Used when the vendor sends no `Retry-After` |
| Follower poll interval | 100 ms | |
| Retries | HTTP ≤ 1, Redis ≤ 1 (idempotent ops only), under the conditions in [0021](0021-failure-taxonomy-and-retry-policy.md) | |
| `REDIS_HOST` | **none — required** | No silent magic host (brief); unset → `BAD_CONFIG`, exit 2 |
| `REDIS_PORT` | 6379 | A port, not a host; standard Redis port |

Correction noted during the decision: the originally proposed limit of 10 calls / 10 s is
60/min, double the ~30/min CoinGecko free-tier figure it cited, so it was lowered to 5 / 10 s.
**Verify against CoinGecko's current public limits** before relying on it; the keyless public API
may allow less than 30/min.

### Consequences

- Good: invariant holds (2000 < 3000 < 4000 < 5000).
- Good: the rate limit is a safety net; normal load stays under it thanks to the lock.
- Bad: data can be up to 5 s old on a cache hit — visible via `as_of_unix`.
