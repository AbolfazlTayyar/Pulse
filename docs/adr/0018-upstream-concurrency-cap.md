# 0018 — Upstream concurrency cap: one in-flight vendor call per source

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief asks what we cap ("timeouts, concurrent upstream calls"). The rate limit
([0012](0012-fixed-window-rate-limit.md)) caps calls *per window*, but not how many run *at the
same time*. Unlimited upstream concurrency must never be possible.

## Decision Drivers

- Never allow unbounded concurrent vendor requests, whatever the host's parallelism.
- Avoid adding coordination state that can disagree with the lock.
- Keep the bound explicit and visible in configuration.

## Considered Options

1. The per-source single-flight lock is the cap: at most **1** in-flight vendor call per source
2. Redis counting semaphore (`mkt:sem:{source}`, ZSET of expiring leases) with configurable N

## Decision Outcome

Chosen option: **1 — the lock is the cap (1 per source)**.

- Only the holder of `mkt:lock:{source}` may call the vendor
  ([0008](0008-redis-single-flight-lock-and-snapshots.md)), so concurrent upstream calls per source
  are ≤ 1 by construction, across all processes and hosts sharing the Redis.
- `MAX_CONCURRENT_UPSTREAM` is a documented config value with default `1`. `config.lua` rejects any
  other value (exit 2) with a message pointing to this ADR, so the cap is explicit rather than
  implied, and changing it requires a new ADR.
- Total upstream concurrency across all sources ≤ number of configured sources (one active per
  invocation today, since `MARKET_SOURCE` selects one).

Bounds that together keep upstream traffic finite:

| Bound | Value | Mechanism |
|---|---|---|
| Concurrent calls per source | 1 | lock |
| Calls per window per source | 5 / 10 s | fixed-window rate limit |
| Duration of one call | 2000 ms | `SOURCE_TIMEOUT_MS` |
| Retries per call | ≤ 1, within deadline | `deadline.lua` |
| Backoff after 429 | `Retry-After` or 30 s | `mkt:cooldown:{source}` |

### Consequences

- Good: zero extra code or Redis keys; impossible for lock and cap to disagree.
- Good: CoinGecko batches symbols, so one call serves everyone — more concurrency wouldn't help.
- Bad: a request for symbols outside the current leader's set waits for the next lock cycle.
- Bad: a vendor that needs one call per symbol would be serialized; that vendor would need option
  2 via a new ADR.
