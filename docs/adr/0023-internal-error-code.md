# 0023 — `INTERNAL_ERROR` for unexpected Lua errors

- Status: accepted
- Date: 2026-09-27
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

`market.lua` wraps dispatch in a top-level protected call, so a bug (an unexpected Lua error)
never prints a stack trace on stdout and the host still gets one JSON object. That body needs a
code, but the stable list in [0003](0003-versioned-output-schema-ticker-v1.md) has none for "our
own code failed".

## Decision Drivers

- Hosts must be able to tell a bug from a vendor, Redis or input problem.
- The code list is a public contract: adding a code is allowed, retyping one is not.

## Considered Options

1. New stable code `INTERNAL_ERROR`
2. Reuse an existing code (e.g. `SOURCE_UNAVAILABLE`)

## Decision Outcome

Chosen option: **1 — `INTERNAL_ERROR`**, exit code `1`.

- Body: `{"ok": false, "code": "INTERNAL_ERROR", "detail": "..."}`. The detail is generic and
  names the invocation id (`inv`); the Lua error and traceback go to stderr only, as an
  `internal_error` event at level `error` ([0019](0019-structured-json-logs-on-stderr.md)).
- Also used when a result body cannot be encoded or written, since that is also our bug.
- Exit `1`, not a new exit code: hosts already treat `1` as "JSON body printed, no usable
  result", and the exit-code contract in [0002](0002-one-shot-cli-worker-with-stdout-contract.md)
  stays unchanged.
- The stable code list becomes: `BAD_ARGS`, `BAD_CONFIG`, `UNKNOWN_SYMBOL`,
  `SOURCE_UNAVAILABLE`, `RATE_LIMITED`, `BAD_PAYLOAD`, `PRICE_UNAVAILABLE`, `REDIS_UNAVAILABLE`,
  `DEADLINE_EXCEEDED`, `INTERNAL_ERROR`.

Option 2 was rejected: a host would retry or alert on a vendor outage that never happened, and
bugs would be invisible in dashboards.

### Consequences

- Good: bugs are visible as their own code and correlate to stderr through `inv`.
- Good: additive change to `ticker.v1`'s error vocabulary, no schema version bump.
- Bad: hosts with an exhaustive switch over codes must add one case.
