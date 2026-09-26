# 0011 — Vendor failure: `ok:false` + non-zero exit, with last-good data attached

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

With Redis up, fresh data can still be unobtainable for `fetch`: the vendor times out or returns
5xx, returns 429, our shared rate limit or cooldown blocks the call, or a follower's deadline
expires while the leader is still fetching. The brief says vendor/network errors produce
`{"ok": false, "code": "SOURCE_UNAVAILABLE", ...}` and a **non-zero exit**. At the same time,
a last-good snapshot is often available and useful to the host.

## Decision Drivers

- Match the brief literally: a vendor failure is never reported as success.
- Same outage → same exit code in every process, regardless of timing.
- Don't throw away usable last-good data.

## Considered Options

1. `ok:true`, exit 0, serve stale items (hides vendor failures behind a success exit code)
2. `ok:false`, exit 1, and still include last-good items marked `stale: true`
3. Leader returns `ok:false`; followers that timed out serve stale with exit 0

## Decision Outcome

Chosen option: **2 — `ok:false` + exit 1, last-good items attached**.

Rule for `fetch`: if **any** requested (valid) symbol could not be refreshed, the response is
`ok: false` with a stable code and exit `1`. The body is still a full `ticker.v1` document:
fresh items as usual, last-good items with `stale: true`, and symbols with no data at all in
`errors[]`.

| Situation | `code` |
|---|---|
| Vendor timeout, connect error, 5xx | `SOURCE_UNAVAILABLE` |
| Vendor 429, `mkt:cooldown:{source}` active, shared rate limit exhausted | `RATE_LIMITED` |
| Follower waited until its deadline and the leader never wrote | `DEADLINE_EXCEEDED` |
| Vendor payload undecodable ([0021](0021-failure-taxonomy-and-retry-policy.md)) | `BAD_PAYLOAD` |

```json
{
  "ok": false,
  "code": "SOURCE_UNAVAILABLE",
  "detail": "coingecko: timeout after 2000ms",
  "schema": "ticker.v1",
  "as_of_unix": 1726899000,
  "source": "coingecko",
  "items": [
    { "symbol": "BTC", "...": "...", "as_of_unix": 1726900000, "stale": false },
    { "symbol": "ETH", "...": "...", "as_of_unix": 1726899000, "stale": true }
  ],
  "errors": [],
  "meta": { "cache": "mixed", "partial": false, "redis_ms": 2, "http_ms": 2001 }
}
```

- On vendor **429**, the leader sets `mkt:cooldown:{source}` with TTL = `Retry-After` header
  (default 30 s). While it exists, no process calls the vendor.
- Last-good lives for `SNAPSHOT_KEEP_S`. Staleness is always marked per item
  ([0003](0003-versioned-output-schema-ticker-v1.md)); stale data is never presented as fresh.
- Unknown/invalid symbols alone are **not** a vendor failure: they keep partial-success
  semantics ([0010](0010-partial-success-semantics.md)).
- `snapshot` and `convert` never call the vendor, so stale data there is not a failure: they
  return `ok: true` with `stale: true` ([0020](0020-convert-output-schema-convert-v1.md),
  [0022](0022-snapshot-and-health-semantics.md)).

### Consequences

- Good: matches the brief — "break the vendor" always yields `ok:false` and exit 1.
- Good: consistent across leader and followers; hosts get one rule.
- Good: hosts that accept stale data still have it in `items`.
- Bad: during an outage every `fetch` exits 1 even though stale data was returned; hosts that
  are fine with stale data should prefer `snapshot`.
- Bad: error bodies for `fetch` are larger than the minimal `{ok, code, detail}` shape.
