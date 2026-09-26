# 0016 — busted for automated tests

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

Core logic (decimal math, validation, adapters, JSON patch, Redis coordination) must be verified
without depending on live, geo-blocked vendors.

## Considered Options

1. busted (luarocks)
2. Plain `tests/run.lua` with `assert`
3. Manual checks only

## Decision Outcome

Chosen option: **1 — busted**, run with `docker compose run --rm app busted`.

Coverage targets:
- Unit: `decimal`, `cli` validation (incl. shell metacharacters), `normalize`, patched `dkjson`,
  `cache` LRU eviction.
- Adapters: recorded fixture JSON in `tests/fixtures/<source>/` served via `SOURCE_URL`.
- Integration: lock/snapshot/rate-limit against the compose Redis; Redis-down → exit 3.

### Consequences

- Good: standard tool, readable specs, works in the Docker image.
- Bad: one more luarocks dependency in the image.
