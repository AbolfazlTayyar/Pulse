# 0013 — Own minimal RESP Redis client

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

We need `SET NX PX`, `GET`/`MGET`, `INCR`, `EXPIRE`, `EVAL`, `PING`, `AUTH` with strict
connect and read timeouts.

## Considered Options

1. Own RESP2 client over luasocket (~150 lines)
2. `redis-lua` from luarocks

## Decision Outcome

Chosen option: **1 — own client** in `src/redis_client.lua`.

- `connect(host, port, timeout_ms)` → `socket.tcp()` with `settimeout`; optional `AUTH`.
- `call(...)` encodes a RESP array, reads one reply (simple string, error, integer, bulk,
  array) with the same timeout.
- `eval(script, keys, args)` for atomic lock release and the rate-limit counter.
- Every error returns `nil, err`, never raises across module boundaries; callers map it to
  `REDIS_UNAVAILABLE` ([0009](0009-fail-closed-when-redis-unavailable.md)).

### Consequences

- Good: full control of timeouts; no dependency on an unmaintained library.
- Good: small, readable, unit-testable against a real Redis in Docker.
- Bad: we own protocol bugs; covered by tests. No pipelining, clustering or RESP3 (not needed).
