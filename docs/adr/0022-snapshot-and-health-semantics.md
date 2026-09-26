# 0022 — `snapshot` (cache-only) and `health.v1` semantics

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief says `snapshot` returns last-known data "without necessarily hitting the vendor", and
`health` prints Redis ping, last successful fetch time and process status — never a fake
always-OK. Neither command's exact behaviour or output was defined.

## Considered Options

`snapshot` on a never-fetched symbol:
1. Cache only; per-symbol `PRICE_UNAVAILABLE`
2. Fetch on miss

`health` verdict:
A. Healthy = Redis reachable; source info is informational
B. Also unhealthy when the last fetch is old or a cooldown is active

## Decision Outcome

Chosen: **1 + A**.

### `snapshot --symbols BTC,ETH`

- Prints `ticker.v1` ([0003](0003-versioned-output-schema-ticker-v1.md)). **Never calls the
  vendor**, never takes the lock, never consumes rate limit.
- Reads the daemon LRU first (daemon mode), then Redis.
- Symbol with no snapshot → `errors[]` with `PRICE_UNAVAILABLE` (partial success). All missing →
  `ok: false`, exit `1`.
- Old data is returned `ok: true`, exit `0`, with `stale: true` per item — returning last-known
  data is the command's purpose, so staleness is information, not failure.
- Redis down → `REDIS_UNAVAILABLE`, exit `3` ([0009](0009-fail-closed-when-redis-unavailable.md)).

### `health`

```json
{
  "ok": true,
  "schema": "health.v1",
  "as_of_unix": 1726900100,
  "process": { "ok": true, "lua": "Lua 5.4", "version": "0.1.0" },
  "redis":   { "ok": true, "latency_ms": 1 },
  "source": {
    "name": "coingecko",
    "last_fetch_unix": 1726900000,
    "last_fetch_age_s": 100,
    "vendor_calls": 42,
    "cooldown_active": false
  }
}
```

- `ok` = `redis.ok`, from a real `PING` with `REDIS_TIMEOUT_MS`. Exit `0` if reachable, `3` if
  not.
- `source` fields come from `mkt:meta:last_fetch:{source}`, `mkt:stats:vendor_calls:{source}` and
  `mkt:cooldown:{source}`. `last_fetch_unix` / `last_fetch_age_s` are `null` if never fetched.
  When Redis is down, `redis` is `{ "ok": false, "error": "..." }` and `source` values are `null`.
- `health` never calls the vendor (it must stay cheap and must not consume rate limit).
- The source block is **informational**: an on-demand worker is not unhealthy just because
  nobody fetched recently. Hosts that want freshness alerts can threshold `last_fetch_age_s`.

### Consequences

- Good: `snapshot` and `health` add zero vendor load and are safe to call at any rate.
- Good: `health` is real (Redis round-trip) and exposes enough to diagnose coalescing and 429s.
- Bad: `snapshot` right after a cold start returns `PRICE_UNAVAILABLE` until something ran
  `fetch`.
- Bad: `health` doesn't prove the vendor is reachable; the source block shows recent evidence
  instead.
