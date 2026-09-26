# 0003 — Versioned output schema `ticker.v1`

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

Hosts parse our stdout. Vendors (CoinGecko, Binance, Kraken) all return different JSON shapes.
How do we keep the host-facing contract stable while sources change or are added?

## Decision Drivers

- Brief requires a schema version so a second source can be added without changing the print
  contract.
- Hosts must be able to branch on stable machine-readable error codes.

## Considered Options

1. Frozen canonical schema with an explicit version field (`"schema": "ticker.v1"`)
2. Pass vendor JSON through with light renaming
3. Unversioned canonical schema

## Decision Outcome

Chosen option: **1 — frozen, versioned canonical schema**.

Success body:

```json
{
  "ok": true,
  "schema": "ticker.v1",
  "as_of_unix": 1726900000,
  "source": "coingecko",
  "items": [
    { "symbol": "BTC", "quote": "USD", "price": "67210.12",
      "volume_24h": "12345.67", "change_24h_pct": "-1.24",
      "as_of_unix": 1726900000, "stale": false }
  ],
  "errors": [ { "symbol": "FAKECOIN", "code": "UNKNOWN_SYMBOL", "detail": "..." } ],
  "meta": { "cache": "hit", "partial": true, "redis_ms": 2, "http_ms": 180 }
}
```

Error body: `{ "ok": false, "code": "<CODE>", "detail": "..." }`. When `fetch` fails because of
the vendor, the error body additionally carries the full `ticker.v1` fields with any last-good
items ([0011](0011-vendor-failure-returns-error-with-last-good-data.md)).

Field semantics:
- `items[].as_of_unix` — when the vendor data for *that item* was fetched.
- `items[].stale` — `true` when the item is older than `SNAPSHOT_FRESH_S` (served as last-good,
  see [0011](0011-vendor-failure-returns-error-with-last-good-data.md)). Freshness is per item, never implied.
- Top-level `as_of_unix` — the **oldest** item's `as_of_unix`, so a host checking only the top
  level never overestimates freshness.
- `meta.partial` — always present; `true` when `items` and `errors` are both non-empty
  ([0010](0010-partial-success-semantics.md)).
- `meta.cache` — how the response was produced: `hit` (fresh Redis snapshots), `miss` (this
  process fetched), `coalesced` (another process fetched while we waited), `stale` (all items
  last-good), `memory` (daemon LRU), `mixed` (items came from different paths, e.g. some fresh
  and some stale).
- `meta.http_ms` is `0` when no vendor call was made.

Stable error codes: `BAD_ARGS`, `BAD_CONFIG`, `UNKNOWN_SYMBOL`, `SOURCE_UNAVAILABLE`, `RATE_LIMITED`,
`BAD_PAYLOAD`, `PRICE_UNAVAILABLE`, `REDIS_UNAVAILABLE`, `DEADLINE_EXCEEDED`.

`fetch` and `snapshot` print `ticker.v1`. `convert` prints `convert.v1`
([0020](0020-convert-output-schema-convert-v1.md)) and `health` prints `health.v1`
([0022](0022-snapshot-and-health-semantics.md)); the minimal error body is shared by all commands.

Rules: fields in `ticker.v1` are never removed or retyped. Adding optional fields is allowed;
anything breaking becomes `ticker.v2`.

### Consequences

- Good: sources are swappable behind adapters ([0006](0006-pluggable-market-sources-coingecko-default.md)).
- Good: `meta.cache` makes coalescing observable in load tests.
- Good: per-item `as_of_unix` + `stale` mean a mixed fresh/stale response is never presented as
  fully fresh.
- Good: `meta.partial` lets hosts detect incomplete results without scanning `errors[]`.
- Bad: vendor-specific extras are dropped unless added as optional fields.
