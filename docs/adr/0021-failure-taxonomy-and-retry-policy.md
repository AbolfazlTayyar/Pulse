# 0021 — Failure taxonomy, retry policy, vendor payload validation, explicit config

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief requires a failure taxonomy (recoverable, retryable with a cap, fatal) and says
unbounded retries fail review. Failure handling was spread across several ADRs, the Redis retry
policy was undefined, nothing prevented a malformed vendor payload from being cached, and the
brief forbids "silent magic hosts" in configuration.

## Decision Drivers

- Every failure maps to exactly one stable code and exit code.
- Retries are bounded and never produce ambiguous shared state.
- A bad payload must never poison the shared cache.
- Configuration is explicit and validated before any work starts.

## Considered Options (Redis retries)

1. Retry once, only connect failures and idempotent operations
2. No retries
3. Retry any operation once

## Decision Outcome

Chosen: **option 1** for Redis, plus the taxonomy, HTTP retry rule, validation and config rules
below.

### Taxonomy

| Class | Examples | Handling | Code / exit |
|---|---|---|---|
| **Fatal — caller** | bad args, shell metacharacters, amount out of limits | reject before any I/O, no retry | `BAD_ARGS` / 2 |
| **Fatal — config** | `REDIS_HOST` unset, invalid numeric env, `MAX_CONCURRENT_UPSTREAM ≠ 1` | reject at startup, no retry | `BAD_CONFIG` / 2 |
| **Retryable, capped — Redis** | connect refused, timeout | ≤ 1 retry (rules below), then fail closed | `REDIS_UNAVAILABLE` / 3 |
| **Retryable, capped — vendor** | connect error, 5xx | ≤ 1 retry (rules below), then report | `SOURCE_UNAVAILABLE` / 1 |
| **Not retried — vendor** | timeout, 429, rate limit, cooldown | no retry; cooldown on 429 | `SOURCE_UNAVAILABLE` / `RATE_LIMITED` / 1 |
| **Poison — whole payload** | undecodable JSON, wrong shape | nothing cached, last-good kept | `BAD_PAYLOAD` / 1 |
| **Poison — one row** | missing field, non-decimal price, price ≤ 0 | row in `errors[]`, not cached; others proceed | `BAD_PAYLOAD` per symbol |
| **Per symbol** | unknown symbol | row in `errors[]` | `UNKNOWN_SYMBOL`, partial ([0010](0010-partial-success-semantics.md)) |
| **Budget** | deadline reached | stop, print what we have | `DEADLINE_EXCEEDED` / 1 |

`fetch` vendor-side failures always attach last-good items
([0011](0011-vendor-failure-returns-error-with-last-good-data.md)).

### Redis retry rules

- Retry **once**, after reconnecting, only for: connection failures before a command was sent,
  and idempotent commands — `PING`, `GET`, `MGET`, `SET` of a snapshot/meta value, `EVAL` of
  the compare-and-delete lock release.
- **Never retry** `INCR` / rate-limit `EVAL` (could double-count) or `SET NX` lock acquisition
  (outcome ambiguous: we might already hold the lock). A failure there → `REDIS_UNAVAILABLE`,
  exit 3; a lock we might hold simply expires via its TTL.
- A retry is attempted only if the remaining deadline exceeds `REDIS_TIMEOUT_MS`.

### HTTP retry rules

- At most **one** retry, only for connect errors and 5xx.
- Never retry timeouts (the full `SOURCE_TIMEOUT_MS` is already spent), 4xx, or 429.
- A retry is attempted only if **both** the remaining deadline and the remaining lock TTL exceed
  `SOURCE_TIMEOUT_MS`; otherwise the leader could still be fetching after its lock expired and a
  second leader could start ([0008](0008-redis-single-flight-lock-and-snapshots.md)).
- The vendor-call counter is incremented for the retry too (it counts attempts).

### Vendor payload validation (structural only)

Before anything is written to Redis, `normalize.lua` checks each row: required fields present;
`price`, `volume_24h`, `change_24h_pct` are valid decimal strings; `price > 0`. Failing rows go
to `errors[]` as `BAD_PAYLOAD` and are never cached. An undecodable payload caches nothing and
leaves existing last-good snapshots intact. No sanity band against previous prices — real
crashes and spikes must not be rejected.

### Explicit configuration

`config.lua` reads and validates all env vars once at startup. `REDIS_HOST` has **no default**
(brief: no silent magic hosts); unset → `BAD_CONFIG`, exit 2. Numeric values must parse as
positive integers and satisfy `SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS`. Vendor base URLs
are adapter constants, overridable via `SOURCE_URL`, and logged at `debug` level.

### Consequences

- Good: one table answers "what happens when X fails" for hosts and reviewers.
- Good: no retry can double-count, steal a lock, or outlive the lock.
- Good: the shared cache only ever contains validated rows.
- Bad: a transient blip during `INCR`/`SET NX` fails the invocation instead of retrying; the host
  may re-run it.
- Bad: running locally requires setting `REDIS_HOST`, even for `127.0.0.1`.
