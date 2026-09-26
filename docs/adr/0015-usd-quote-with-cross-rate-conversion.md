# 0015 — USD quote currency with cross-rate conversion

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief's example uses `quote: "USDT"` (Binance style). CoinGecko quotes natively in fiat
(`vs_currencies=usd`). `convert --from BTC --to USDT` must work either way.

## Considered Options

1. USD as default canonical quote (configurable via `MARKET_QUOTE`); cross-rate conversion
2. USDT everywhere, matching the brief's example literally

## Decision Outcome

Chosen option: **1 — USD default, configurable**.

`convert --from A --to B --amount X` uses cached snapshots only (no vendor call):
- `B == quote` → `X × price(A)`
- `A == quote` → `X ÷ price(B)`
- otherwise → `X × price(A) ÷ price(B)` (e.g. BTC→USDT via USDT's own USD price)

Missing price → `PRICE_UNAVAILABLE`, exit `1`. All math via `decimal.lua`
([0007](0007-money-as-decimal-strings.md)). Output schema, precision (`CONVERT_SCALE`) and
rounding (half-even) are defined in [0020](0020-convert-output-schema-convert-v1.md).

### Consequences

- Good: matches CoinGecko's native data; any pair works through cross-rates.
- Bad: output differs from the brief's example (`USD` instead of `USDT`); documented in README.
- Bad: cross-rates depend on two snapshots that may have different `as_of_unix`; the response
  reports the older one, and `stale: true` if either input is stale.
