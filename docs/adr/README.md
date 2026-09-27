# Architecture Decision Records

Format: [MADR](https://adr.github.io/madr/). One decision per file, numbered, never renumbered.
To change a decision, add a new ADR and mark the old one `superseded by NNNN`.
See [0001](0001-record-architecture-decisions.md).

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions (MADR, one file each) | accepted |
| [0002](0002-one-shot-cli-worker-with-stdout-contract.md) | One-shot CLI worker with stdout JSON contract, no HTTP | accepted |
| [0003](0003-versioned-output-schema-ticker-v1.md) | Versioned output schema `ticker.v1`, per-item freshness, `meta.partial`, stable error codes | accepted |
| [0004](0004-lua-5-4-runtime.md) | Lua 5.4 runtime | accepted |
| [0005](0005-docker-compose-dev-environment.md) | Docker Compose development environment | accepted |
| [0006](0006-pluggable-market-sources-coingecko-default.md) | Pluggable sources; CoinGecko default | accepted |
| [0007](0007-money-as-decimal-strings.md) | Money as decimal strings; patched dkjson; own arbitrary-precision math | accepted |
| [0008](0008-redis-single-flight-lock-and-snapshots.md) | Redis single-flight lock (= in-flight dedup) + TTL snapshots + vendor-call counter | accepted |
| [0009](0009-fail-closed-when-redis-unavailable.md) | Fail closed when Redis is unavailable | accepted |
| [0010](0010-partial-success-semantics.md) | Partial success, exit 0 | accepted |
| [0011](0011-vendor-failure-returns-error-with-last-good-data.md) | Vendor failure → `ok:false` + exit 1, last-good items attached; 429 cooldown | accepted |
| [0012](0012-fixed-window-rate-limit.md) | Fixed-window shared rate limit | accepted |
| [0013](0013-own-resp-redis-client.md) | Own minimal RESP Redis client | accepted |
| [0014](0014-daemon-over-stdin-ndjson-with-in-process-lru.md) | Daemon over stdin NDJSON + bounded LRU | accepted |
| [0015](0015-usd-quote-with-cross-rate-conversion.md) | USD quote, cross-rate conversion | accepted |
| [0016](0016-busted-for-tests.md) | busted for tests | accepted |
| [0017](0017-default-tuning-values.md) | Default tuning values (balanced) | accepted |
| [0018](0018-upstream-concurrency-cap.md) | Upstream concurrency cap: 1 in-flight call per source | accepted |
| [0019](0019-structured-json-logs-on-stderr.md) | Structured JSON-lines logs on stderr | accepted |
| [0020](0020-convert-output-schema-convert-v1.md) | `convert` output schema `convert.v1` (legs, half-even, cache-only) | accepted |
| [0021](0021-failure-taxonomy-and-retry-policy.md) | Failure taxonomy, retry policy, vendor payload validation, explicit config | accepted |
| [0022](0022-snapshot-and-health-semantics.md) | `snapshot` (cache-only) and `health.v1` semantics | accepted |
| [0023](0023-internal-error-code.md) | `INTERNAL_ERROR` code (exit 1) for unexpected Lua errors | accepted |
| [0024](0024-binance-usd-quote-as-usdt.md) | Binance: `MARKET_QUOTE=USD` fetches USDT pairs, labelled `USDT` | accepted |
