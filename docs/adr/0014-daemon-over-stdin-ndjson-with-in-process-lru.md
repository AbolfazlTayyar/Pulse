# 0014 — Daemon mode over stdin NDJSON, with an in-process LRU

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief asks us to show process-local vs shared state. In one-shot mode, Lua tables die with
the process, so in-process caching is useless and Redis is the real cache. The optional `daemon`
command is where in-process memory can be shown — still without HTTP.

## Considered Options

Transport:
1. stdin NDJSON only; one JSON response per line on stdout
2. stdin + Unix domain socket

## Decision Outcome

Chosen option: **1 — stdin NDJSON only**.

- Request line: `{"id": "...", "command": "fetch", "symbols": ["BTC","ETH"]}` (same commands
  and validation as the CLI).
- Response line: the same body the one-shot command would print, plus the echoed `id`.
- EOF on stdin → clean exit `0`. A malformed line → error response for that line; the daemon keeps
  running.
- The Redis connection is reused across commands and reconnected on failure.

In-process LRU (`src/cache.lua`):
- Holds normalized tickers keyed by `{source}:{symbol}`.
- Bounds: **max 256 entries** (`CACHE_MAX_ENTRIES`) and **max ~1 MiB** (`CACHE_MAX_BYTES`,
  estimated by encoded JSON length); whichever limit is hit first evicts the least-recently-used
  entry. An entry larger than `CACHE_MAX_BYTES` on its own is not cached. Both values must be
  positive integers; invalid values fail config validation (exit 2).
- An entry is served only while younger than `SNAPSHOT_FRESH_S`; otherwise Redis is checked.
- In one-shot mode the LRU exists but is effectively empty per process — documented, not hidden.

### Consequences

- Good: shows real in-process memory (`meta.cache: "memory"` for LRU hits) and saves Redis
  round-trips.
- Good: no socket, no port — clearly not a server.
- Bad: one daemon handles commands sequentially; parallelism still comes from the host running
  several daemons.
- Bad: Unix socket clients are not supported.
