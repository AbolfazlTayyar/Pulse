# 0020 — `convert` output schema `convert.v1`

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

`ticker.v1` ([0003](0003-versioned-output-schema-ticker-v1.md)) describes a list of prices.
`convert --from A --to B --amount X` returns one computed amount derived from one or two cached
prices ([0015](0015-usd-quote-with-cross-rate-conversion.md)). It needs its own stable contract,
including precision, rounding, and what happens when prices are missing or stale.

## Decision Drivers

- Hosts must be able to audit how a money amount was computed.
- Same principles as `ticker.v1`: versioned, decimal strings, freshness never implied.
- Brief: `convert` uses cached/normalized prices; missing data fails with a stable code.

## Considered Options

Shape:
1. Own schema `convert.v1` with result, effective rate and the price legs used
2. Own schema `convert.v1`, result and rate only
3. Reuse the `ticker.v1` envelope plus a `conversion` object

Rounding: A. fixed scale, half-even · B. fixed scale, half-up · C. truncate

Missing price: I. cache only, fail · II. fetch on miss

Stale leg: α. convert and mark stale · β. reject (`PRICE_STALE`) · γ. `--max-age` flag

## Decision Outcome

Chosen: **1 + A + I + α**.

```json
{
  "ok": true,
  "schema": "convert.v1",
  "as_of_unix": 1726899998,
  "source": "coingecko",
  "from": "BTC",
  "to": "USDT",
  "amount": "1.5",
  "result": "100812.34414876",
  "rate": "67208.22943251",
  "stale": false,
  "legs": [
    { "symbol": "BTC",  "quote": "USD", "price": "67210.12",
      "as_of_unix": 1726900000, "stale": false },
    { "symbol": "USDT", "quote": "USD", "price": "1.00002813",
      "as_of_unix": 1726899998, "stale": false }
  ],
  "meta": { "cache": "hit", "redis_ms": 1, "http_ms": 0 }
}
```

Computation (all in `decimal.lua`, never floats):

| Case | `result` | `rate` | `legs` |
|---|---|---|---|
| `A == B` | `X` | `1` | `[]` |
| `B == quote` | `X × p(A)` | `p(A)` | `[A]` |
| `A == quote` | `X ÷ p(B)` | `1 ÷ p(B)` | `[B]` |
| otherwise | `X × p(A) ÷ p(B)` | `p(A) ÷ p(B)` | `[A, B]` |

- Multiplications are exact. Each output value is computed from the exact inputs with a single
  final rounding to `CONVERT_SCALE` decimal places (default 8), **round half-to-even**.
  Consequently `result` is not recomputed as `amount × rate` (that would round twice) and may
  differ from it in the last digit.
- `result` and `rate` are always formatted with exactly `CONVERT_SCALE` decimals.
- Top-level `as_of_unix` = the oldest leg's; `stale` = `true` if any leg is stale.
- `meta.cache` ∈ `hit`, `stale`, `mixed`, `memory` (daemon). `http_ms` is always `0`.

Failure behaviour:
- **Missing price** for any leg → `{"ok":false,"code":"PRICE_UNAVAILABLE","detail":"no cached
  price for DOGE"}`, exit `1`. `convert` **never calls the vendor**.
- **Stale leg** → convert anyway, mark `stale: true` on the leg and top level, exit `0`.
  `convert` is cache-only, so an old price is not a vendor failure — unlike `fetch`
  ([0011](0011-vendor-failure-returns-error-with-last-good-data.md)).
- **Invalid amount** (not a positive decimal string, or beyond the digit limits enforced by
  `cli.lua`) → `BAD_ARGS`, exit `2`.
- Redis down → `REDIS_UNAVAILABLE`, exit `3` ([0009](0009-fail-closed-when-redis-unavailable.md)).

### Consequences

- Good: fully auditable — a host can recompute the result from `legs`.
- Good: fast and predictable; `convert` adds zero vendor load.
- Good: half-even rounding has no systematic bias over many conversions.
- Bad: `convert` right after a cold start fails until something has run `fetch`.
- Bad: a second schema to document and test.
