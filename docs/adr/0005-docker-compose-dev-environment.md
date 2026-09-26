# 0005 — Docker Compose development environment

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

Development happens on Windows 10. Lua C modules (luasocket, luasec) are painful to build natively
on Windows, and Redis has no official Windows build. The brief penalizes projects that "only work
on your laptop".

## Decision Drivers

- Reproducible for reviewers with one command.
- Linux behaviour matching a real host (signals, `xargs -P`, paths).

## Considered Options

1. Docker Compose: `app` (Lua 5.4 + luarocks + deps) and `redis` services
2. WSL (Ubuntu) with native installs
3. Native Windows Lua + luarocks

## Decision Outcome

Chosen option: **1 — Docker Compose**.

- `app` image: Lua 5.4, luarocks, luasocket, luasec, busted. Source is bind-mounted.
- `redis` service: official Redis image, port 6379.
- Commands can run via `docker compose run --rm app ...` (the app container is the "host").

**Native path, documented alongside:** the brief's host runs `lua market.lua ...` directly, so
the README also documents Linux/WSL: `apt install lua5.4 liblua5.4-dev luarocks`, then
`luarocks install --only-deps market-dev-1.rockspec` (the rockspec at the repo root lists
luasocket, luasec, busted), a local or containerized Redis, and `REDIS_HOST` set explicitly.
`market.lua` prepends its own directory to `package.path`, so it runs from any cwd without
setting `LUA_PATH`. The load test is documented for both paths.

### Consequences

- Good: one-command setup; same environment for developer and reviewer.
- Good: load test (`seq | xargs -P 50`) runs under Linux as the brief assumes.
- Bad: requires Docker Desktop; container start adds latency — load numbers must be measured
  *inside* one container, not with one `docker compose run` per invocation.
- Note: containers use the host's network, so the geo-blocking in
  [0006](0006-pluggable-market-sources-coingecko-default.md) applies inside Docker too.
