# 0009 — Fail closed when Redis is unavailable

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief requires a documented choice between fail-closed and serving degraded data when Redis
is down.

## Decision Drivers

- Redis is the only thing preventing 1000 workers from hitting the vendor at once.
- Behaviour must be predictable and easy for hosts to handle.

## Considered Options

1. Fail-closed: exit `3`, `{"ok":false,"code":"REDIS_UNAVAILABLE"}`
2. Degraded: serve in-process data or make an uncoordinated vendor call

## Decision Outcome

Chosen option: **1 — fail-closed**.

- Redis connect/command timeout → exit `3` with a structured JSON body.
- `health` still prints a full body (`redis: {ok: false, error}`, `process: ok`) and exits `3`.
- In daemon mode, an in-process LRU may answer `snapshot` if data is younger than
  `SNAPSHOT_FRESH_S`; it never triggers a vendor call without Redis.

### Consequences

- Good: a Redis outage can never become a vendor DDoS or a ban of our IP.
- Good: one clear signal (exit 3) for hosts to alert on.
- Bad: during a Redis outage, one-shot callers get no data even if the vendor is up.
