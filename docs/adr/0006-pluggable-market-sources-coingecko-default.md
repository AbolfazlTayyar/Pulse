# 0006 — Pluggable market sources, CoinGecko as default

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

We need one public market API (brief) and the design must allow adding a second one without
changing the print schema. Which vendor, and how are vendors plugged in?

## Decision Drivers

- Reachability and latency from the development network.
- Price representation (strings preferred over floats).
- No API key required.
- Swappability is graded.

## Measurement (2026-09-26, from the dev network, 6 requests each)

| Provider | Result | Latency |
|---|---|---|
| CoinGecko `/simple/price` | 200 OK | ~0.39–0.60 s (1.09 s cold) |
| Binance `/api/v3/ticker/24hr` (+ `api1`, `data-api.binance.vision`) | timeout; binance.us → 451 "restricted location" | — |
| Kraken `/0/public/Ticker` | 403, Cloudflare error 1009 (country blocked) | — |

## Considered Options

1. Adapter registry selected by `MARKET_SOURCE`, three adapters, CoinGecko default
2. Adapter interface, CoinGecko only
3. CoinGecko hardcoded

## Decision Outcome

Chosen option: **1 — adapter registry with `coingecko` (default), `binance`, `kraken`**.

Adapter contract (`src/source/<name>.lua`):
- `name` — string used in `source` field and Redis keys.
- `fetch(symbols, quote, timeout_ms)` → canonical rows
  `{symbol, quote, price, volume_24h, change_24h_pct}` (all decimal strings) + per-symbol errors.
- Each adapter owns its symbol mapping (CoinGecko: `BTC → bitcoin`; Kraken: `BTC → XBT`).

CoinGecko is default because it is the only reachable source. Binance and Kraken adapters are
tested against recorded fixture JSON served via `SOURCE_URL`.

### Consequences

- Good: adding a source = one adapter file + registry entry; `ticker.v1` unchanged.
- Good: `SOURCE_URL` makes every adapter testable offline.
- Bad: CoinGecko returns prices as JSON **numbers** (e.g. `"usd":84115`), so we need
  string-preserving JSON decoding ([0007](0007-money-as-decimal-strings.md)).
- Bad: CoinGecko's free tier has a strict, variable rate limit
  ([0012](0012-fixed-window-rate-limit.md)).
- Bad: Binance/Kraken adapters are not live-verified from this network.
