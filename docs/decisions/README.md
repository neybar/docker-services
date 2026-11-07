# Architecture decision records

One file per significant decision, numbered in order: `NNNN-short-title.md`. An ADR is never rewritten after it is
accepted. To change a decision, write a new ADR that supersedes it, and set the old one's status to
`Superseded by NNNN`.

## Index

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-public-private-split.md) | Public/private repo split | Accepted | 2026-11-07 |

## Template

```markdown
# NNNN: Title

- **Status:** Proposed | Accepted | Superseded by NNNN
- **Date:** YYYY-MM-DD
- **Links:** issues, PRs, related ADRs

## Context

What forces the decision: the problem, the constraints, what is true today.

## Decision

What was chosen. Short and definite.

## Alternatives considered

Each option that was rejected, and why.

## Consequences

What this makes easier and harder, and the follow-up work it creates.
```

No instance data in an ADR: no host addresses, secrets or live config. Use placeholders (`<nas-ip>`, `<domain>`).
