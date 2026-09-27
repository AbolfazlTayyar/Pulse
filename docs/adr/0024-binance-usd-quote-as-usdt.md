# 0024 — Binance: `MARKET_QUOTE=USD` fetches USDT pairs, labelled `USDT`

- Status: accepted
- Date: 2026-09-27
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

`MARKET_QUOTE` defaults to `USD` ([0015](0015-usd-quote-with-cross-rate-conversion.md)).
Binance's global API has no USD pairs, only USDT, USDC, EUR and others. What does
`MARKET_SOURCE=binance` do with the default quote?

## Considered Options

1. Reject the combination at startup (`BAD_CONFIG`); require `MARKET_QUOTE=USDT`
2. Fetch the `*USDT` pairs and label items `"quote": "USDT"`
3. Fetch the `*USDT` pairs and label them `USD`

## Decision Outcome

Chosen option: **2 — fetch USDT pairs, label them `USDT`**.

- Adapters expose `effective_quote(quote)`: Binance maps `USD → USDT`; every other quote, and
  every other adapter, returns it unchanged.
- Items say what was actually priced (`"quote": "USDT"`). Option 3 was rejected: USDT is not
  USD, and relabelling would silently misstate prices.
- `convert` uses the effective quote as its base currency, so its computation table
  ([0020](0020-convert-output-schema-convert-v1.md)) applies with `USDT` in place of `USD`.

### Consequences

- Good: the default configuration works with every source, and output never lies about the quote.
- Bad: with Binance, `quote` differs from `MARKET_QUOTE`; hosts must read the item's `quote`.
