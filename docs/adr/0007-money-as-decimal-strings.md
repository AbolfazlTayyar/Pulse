# 0007 — Money as decimal strings; string-preserving JSON decoding

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The brief forbids naive floats for prices. Lua JSON libraries decode numbers into Lua floats, and
CoinGecko sends prices as JSON numbers. `convert` also needs arithmetic on prices and amounts.

## Decision Drivers

- No precision loss anywhere between vendor bytes and our stdout.
- No C compilation if avoidable.
- Exact multiply/divide for `convert`.

## Considered Options

JSON decoding:
1. Vendored **dkjson**, patched so numbers decode to their original text
2. lua-cjson plus a tokenizer pre-pass that quotes numeric tokens
3. Own minimal JSON decoder

Arithmetic:
A. Integer + scale in `src/decimal.lua` using plain Lua 5.4 64-bit integers
B. Own arbitrary-precision integer + scale in `src/decimal.lua` (base-10^7 limbs)
C. Vendored `bint` (pure-Lua bignum library) with integer + scale on top
D. 64-bit integers with tight input/scale limits and an `AMOUNT_OUT_OF_RANGE` error

Why A/D fail: `1.5 BTC → USDT` at `67210.12 / 1.00002813` with 8 output decimals needs an
intermediate of ~1.0 × 10²² before the division; 2^63 ≈ 9.2 × 10¹⁸. Ordinary inputs overflow,
so 64-bit only works with limits too restrictive to be useful.

## Decision Outcome

Chosen: **1 + B**.

- `src/vendor/dkjson.lua` (pure Lua, MIT) is vendored with a small patch: number tokens are
  returned as strings. LPeg mode is disabled so the patched path is always used.
- All prices, volumes, percentages and amounts are decimal strings end-to-end.
- `decimal.lua` parses `"67210.12"` → `{digits = <arbitrary-precision integer 6721012>,
  scale = 2}`. The integer is an array of base-10^7 limbs (limb products stay far below 2^63),
  with add, multiply, long division and round-half-even. Formats back to a string. It cannot
  overflow.
- Division is done once, on exact inputs, with guard digits, then rounded half-even to the
  requested scale ([0020](0020-convert-output-schema-convert-v1.md)).
- Input sizes are still bounded by `cli.lua` validation (amount ≤ 30 integer digits and ≤ 18
  decimals; longer → `BAD_ARGS`) so a hostile argument cannot make the math slow.
- Rule: never call `tonumber()` on a money value.

### Consequences

- Good: byte-exact prices; no float surprises (`0.1 + 0.2`).
- Good: no C build for JSON.
- Bad: maintaining a patch on a vendored library; covered by unit tests.
- Bad: dkjson is slower than cjson — irrelevant for payloads of a few KB.
- Good: no overflow for any valid input; no third-party bignum to audit.
- Bad: ~200 lines of arithmetic we own — long division is the risky part; unit tests compare
  against precomputed reference values (e.g. from Python's `decimal`) including rounding ties.
