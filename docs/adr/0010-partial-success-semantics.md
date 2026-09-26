# 0010 — Partial success semantics

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

`fetch BTC,FAKECOIN,ETH` — one symbol is unknown or the vendor omits a field. The brief says one
bad symbol must not crash the process and requires documenting the choice.

## Considered Options

1. Partial success: `ok: true`, good items + `errors[]`, exit `0`; exit `1` only if all fail
2. Partial body but `ok: false`, exit `1` on any failure
3. Fail the whole request on any bad symbol

## Decision Outcome

Chosen option: **1 — partial success, exit 0**.

- Each failed symbol appears in `errors[]` as `{symbol, code, detail}` (e.g. `UNKNOWN_SYMBOL`,
  `BAD_PAYLOAD` for missing/invalid fields).
- `meta.partial` is always present: `true` when some symbols succeeded and some failed, `false`
  when all succeeded.
- If `items` is empty → `ok: false`, exit `1`.
- This covers bad *input* symbols and bad *vendor rows* only. If the vendor call itself fails,
  the whole `fetch` is `ok: false`, exit `1`
  ([0011](0011-vendor-failure-returns-error-with-last-good-data.md)).
- A vendor row that fails validation is reported as `BAD_PAYLOAD` in `errors[]` and is **never
  written to Redis** ([0021](0021-failure-taxonomy-and-retry-policy.md)).
- Each item is parsed in its own protected call (`pcall`), so a poison record cannot abort the
  others.

### Consequences

- Good: hosts get all available data; a typo doesn't hide valid prices.
- Bad: the exit code alone doesn't reveal incompleteness; hosts that care check
  `meta.partial` (one boolean) instead of the exit code.
