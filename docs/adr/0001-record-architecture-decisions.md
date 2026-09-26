# 0001 — Record architecture decisions

- Status: accepted
- Date: 2026-09-26
- Deciders: Abolfazl Tayyar

## Context and Problem Statement

The project makes many design choices up front (runtime, Redis strategy, failure modes, schema).
Reviewers grade the *reasoning*, not only the code, and future changes (e.g. adding a market
source) need to know why things are the way they are.

## Decision Drivers

- The brief grades architecture and requires a written justification for several choices.
- Decisions should be individually revisable without rewriting one big document.

## Considered Options

1. One ADR file per decision in `docs/adr/` (MADR template)
2. A single `docs/ADR.md` with numbered sections
3. No ADRs; only `docs/ARCHITECTURE.md`

## Decision Outcome

Chosen option: **1 — one MADR file per decision in `docs/adr/`**, indexed by
[README.md](README.md).

Rules:
- Files are numbered `NNNN-kebab-title.md` and never renumbered.
- An accepted ADR is not edited in substance; a change of mind is a new ADR that marks the old
  one `superseded by NNNN`.
- `CLAUDE.md` holds the short operational summary; ADRs hold the reasoning and rejected options.

### Consequences

- Good: each decision records its alternatives and trade-offs; easy to supersede one decision.
- Good: `ARCHITECTURE.md` can stay 1–2 pages and link here for detail.
- Bad: more files to keep in sync with `CLAUDE.md`.
