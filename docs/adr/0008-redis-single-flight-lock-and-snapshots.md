# 0008 — Redis single-flight lock and TTL snapshots

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The host runs e.g. `seq 1 200 | xargs -P 50 lua market.lua fetch BTC,ETH`. Without
coordination that is 200 vendor calls for identical data (cache stampede), which triggers
vendor rate limits. Processes share nothing but Redis.

## Decision Drivers

- Most concurrent invocations should print cached JSON, not call the vendor.
- A process may be killed at any time (e.g. at 5 s) — no lock may outlive it indefinitely.
- Use Redis for coordination, not as one blob dump.

## Considered Options

1. Per-source lock (`SET NX PX` + random token) + per-symbol snapshots with TTL; followers poll
2. Per-symbol locks
3. No lock; snapshot cache only (every miss calls the vendor)

## Decision Outcome

Chosen option: **1 — per-source single-flight lock + per-symbol snapshots**.

Keys:

| Key | Purpose |
|---|---|
| `mkt:lock:{source}` | `SET key <token> NX PX LOCK_TTL_MS` |
| `mkt:snapshot:{source}:{symbol}` | last-good ticker JSON incl. `as_of_unix`, TTL `SNAPSHOT_KEEP_S` |
| `mkt:meta:last_fetch:{source}` | unix time of last successful vendor fetch (for `health`) |
| `mkt:stats:vendor_calls:{source}` | counter of real vendor HTTP calls (no TTL); read by the load script and `health` |

Flow for `fetch`:
1. Read snapshots. All younger than `SNAPSHOT_FRESH_S` → print, `cache: "hit"`.
2. Try the lock.
   - **Leader:** rate-limit check → `INCR mkt:stats:vendor_calls:{source}` → HTTP (timeout) →
     normalize → write snapshots → release lock with a compare-and-delete `EVAL` (only if the
     token is still ours) → `cache: "miss"`.
     The leader fetches the union of requested symbols in one vendor call.
   - **Follower:** poll snapshots every ~100 ms until fresh or deadline → `cache: "coalesced"`;
     otherwise report per [0011](0011-vendor-failure-returns-error-with-last-good-data.md).
3. Invariant: `SOURCE_TIMEOUT_MS < LOCK_TTL_MS < DEADLINE_MS < host kill timeout`.

**Killed mid-fetch:** the lock is never released explicitly; it expires after `LOCK_TTL_MS`, and
the next invocation becomes leader. No snapshot is half-written because `SET` is atomic.

Per-symbol locks were rejected: CoinGecko fetches many symbols in one call, so a per-source lock
gives one vendor request per fresh window.

**In-flight deduplication (the brief's optional `mkt:inflight`):** the lock *is* our in-flight
marker. While `mkt:lock:{source}` exists, a fetch is in flight, and every other process waits for
its result instead of starting its own. A separate `mkt:inflight` key would duplicate this state
and could disagree with the lock, so there is none. Because the lock is per source, the same
mechanism caps upstream concurrency at 1 per source
([0018](0018-upstream-concurrency-cap.md)).

**Vendor-call counter:** incremented *before* the HTTP request, so it counts attempts, including
ones that time out or return 429 — the number the vendor sees. `docs/LOAD.md` reports
`after − before` around the load run.

### Consequences

- Good: 200 invocations → a handful of vendor calls (measured in `docs/LOAD.md`).
- Good: crash-safe via TTL; token prevents releasing someone else's lock.
- Bad: followers wait up to the deadline when the leader is slow.
- Bad: a follower asking for a symbol the leader didn't include must wait for the next window or
  return `DEADLINE_EXCEEDED` with last-good items attached
  ([0011](0011-vendor-failure-returns-error-with-last-good-data.md)).
