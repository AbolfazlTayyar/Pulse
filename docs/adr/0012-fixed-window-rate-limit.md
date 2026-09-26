# 0012 — Fixed-window shared rate limit

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

Even with a single-flight lock, lock expiry, many symbol sets and many hosts can add up to more
vendor calls than the vendor allows. A limit shared across all processes is required.

## Considered Options

1. Fixed window: `INCR mkt:rl:{source}:{window}` + `EXPIRE`, atomic via `EVAL`
2. Sliding window log (ZSET)
3. Token bucket (Lua script)

## Decision Outcome

Chosen option: **1 — fixed window**, one atomic `EVAL` round-trip:

```lua
local n = redis.call('INCR', KEYS[1])
if n == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
return n
```

`{window} = floor(now / RATE_LIMIT_WINDOW_S)`. If `n > RATE_LIMIT_PER_WINDOW`, the vendor is not
called and [0011](0011-vendor-failure-returns-error-with-last-good-data.md) applies.

Only the lock holder consumes a token, so the limit counts real vendor calls, not invocations.

### Consequences

- Good: one cheap Redis round-trip; easy to explain and test.
- Bad: up to 2× the limit can occur across a window boundary. Acceptable because the lock and
  `SNAPSHOT_FRESH_S` already keep real call rates far below the cap.
