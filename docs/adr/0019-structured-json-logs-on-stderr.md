# 0019 — Structured JSON-lines logs on stderr

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

stdout is reserved for the result ([0002](0002-one-shot-cli-worker-with-stdout-contract.md)).
Operators still need to see what each worker did: cache hits, lock contention, vendor calls,
rate-limit events, Redis errors. With hundreds of concurrent processes writing to the same log
stream, lines must be attributable and parseable.

## Considered Options

1. JSON lines: one JSON object per line
2. logfmt: `key=value` pairs per line
3. Free-form text

## Decision Outcome

Chosen option: **1 — JSON lines on stderr**, written only by `src/log.lua`.

Every line has:

| Field | Meaning |
|---|---|
| `ts` | UTC timestamp, ISO 8601 with milliseconds |
| `level` | `debug`, `info`, `warn`, `error` (filtered by `LOG_LEVEL`, default `info`) |
| `inv` | random 8-hex-char invocation id, same for all lines of one process run |
| `req` | daemon only: the request `id` from the NDJSON line |
| `event` | stable event name (below) |

Plus event-specific fields.

| Event | Level | Extra fields |
|---|---|---|
| `invocation_start` | info | `command`, `symbols` |
| `invocation_end` | info | `exit_code`, `duration_ms`, `cache` |
| `cache_hit` / `cache_miss` | debug | `symbols`, `layer` (`memory`/`redis`) |
| `lock_acquired` / `lock_busy` / `lock_released` / `lock_lost` | info/debug | `source`, `wait_ms` |
| `vendor_call` | info | `source`, `status`, `http_ms`, `symbols` |
| `rate_limited` | warn | `source`, `count`, `limit` |
| `cooldown_set` / `cooldown_active` | warn | `source`, `ttl_s` |
| `stale_served` | warn | `symbols`, `age_s` |
| `symbol_error` | warn | `symbol`, `code` |
| `redis_error` | error | `op`, `detail` |
| `deadline_exceeded` | error | `stage` |

Rules:
- Never log secrets (`REDIS_PASSWORD`, full env, auth replies).
- Logging must never fail the job: write errors on stderr are swallowed.
- Values are encoded by the same JSON encoder as stdout, so one event is always one line.

### Consequences

- Good: machine-parseable by hosts and log shippers; `inv` correlates lines from one process.
- Good: load tests can cross-check behaviour (`lock_busy` count, `stale_served`).
- Bad: less pleasant to read raw than logfmt; `jq` recommended in README.
