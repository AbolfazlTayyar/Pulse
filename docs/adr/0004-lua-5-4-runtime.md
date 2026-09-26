# 0004 — Lua 5.4 runtime

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief allows Lua 5.3+ or LuaJIT and requires stating which. The choice affects numeric
semantics (important for money) and library availability.

## Decision Drivers

- Decimal math for `convert` needs exact integer arithmetic.
- Fast process startup (spawned many times per second).
- Easy to install in a Docker image with luarocks.

## Considered Options

1. Lua 5.4
2. LuaJIT (Lua 5.1 semantics)
3. Lua 5.3

## Decision Outcome

Chosen option: **1 — Lua 5.4**, because it has native 64-bit integers (`math.type`, `//`),
which make the limb arithmetic in `src/decimal.lua` simple and exact, and it is the current
stable release.

### Consequences

- Good: exact integer limb math (base 10^7 limbs, products < 2^63) without float tricks.
- Good: startup is a few milliseconds — fine for one-shot spawning.
- Bad: slower than LuaJIT for hot loops; irrelevant for our small payloads.
- Note: 64-bit integers alone are *not* enough for money math — ordinary `convert` inputs
  overflow 2^63 — so `decimal.lua` uses arbitrary precision on top of them
  ([0007](0007-money-as-decimal-strings.md)).
