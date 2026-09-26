# 0002 — One-shot CLI worker with a stdout JSON contract (no HTTP)

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

External hosts (Python, Go, bash, systemd, Kubernetes Jobs, CI) need market data from Lua. They
spawn the program many times per second, read its output, check its exit code and may kill it on
timeout. How do results get from Lua to the host?

## Decision Drivers

- Brief: exposing results via HTTP (Lua HTTP API, OpenResty, Flask…) is an automatic fail.
- The host owns concurrency, pooling, retries and cancellation — the worker must be bounded.
- Must be trivially callable from any language.

## Considered Options

1. One-shot CLI: argv + env in, one JSON object on stdout, logs on stderr, exit code
2. Long-running HTTP service in Lua (OpenResty / lua-http)
3. CLI that writes results only into Redis for the host to read

## Decision Outcome

Chosen option: **1 — one-shot CLI with a stdout contract**.

- Entrypoint: `lua market.lua <command> [args...]` (`fetch`, `snapshot`, `convert`, `health`,
  `daemon`).
- **stdout:** exactly one JSON object per invocation. Only `src/output.lua` writes to stdout.
- **stderr:** human logs, never secrets.
- **Exit codes:** `0` ok · `1` business/upstream error (structured JSON still on stdout) ·
  `2` bad arguments or invalid configuration · `3` Redis unavailable.
- Every invocation finishes within `DEADLINE_MS`, set below the host's kill timeout, so we exit
  with a JSON body instead of being killed mid-write.
- Arguments are validated with whitelists; `;`, `|`, `&`, `$`, backticks etc. are rejected and
  user input never reaches a shell.

### Consequences

- Good: process lifecycle = request lifecycle; the host's timeout/kill *is* cancellation.
- Good: no port, no server hardening, no connection management in Lua.
- Good: any language can call it with `subprocess.run` / `exec.Command`.
- Bad: per-invocation cost (process start + Redis connect) on every call; mitigated by fast Lua
  startup and by the optional daemon ([0014](0014-daemon-over-stdin-ndjson-with-in-process-lru.md)).
- Bad: a stray `print()` anywhere breaks host parsing — enforced by the single-writer rule.
