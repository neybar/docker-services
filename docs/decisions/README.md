# Architecture decision records

One file per significant decision, numbered in order: `NNNN-short-title.md`. An ADR is never rewritten after it is
accepted. To change a decision, write a new ADR that supersedes it, and set the old one's status to
`Superseded by NNNN`.

## Index

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-public-private-split.md) | Public/private repo split | Accepted | 2026-11-07 |
| [0002](0002-chains-and-crowdsec-in-file-provider.md) | Every router uses a chain; `crowdsec@file` in the file provider | Accepted | 2026-10-20 |
| [0003](0003-crowdsec-fails-open.md) | CrowdSec bouncer fails open; two scenarios disabled | Accepted | 2026-10-20 |
| [0004](0004-no-host-address-binds.md) | No host addresses in compose | Accepted | 2026-11-06 |
| [0005](0005-embedded-databases-off-nfs.md) | Embedded databases on local NVMe, not NFS | Accepted | 2026-10-03 |
| [0006](0006-restic-backs-up-whole-root.md) | restic backs up all of `/` minus regenerable paths | Accepted | 2026-11-07 |
| [0007](0007-boot-ordering.md) | Boot ordering: Docker requires its mounts, wait for IPv4 | Accepted | 2026-11-07 |
| [0008](0008-beads-on-shared-dolt.md) | Beads on a shared Dolt server for multi-agent work | Accepted | 2026-10-30 |
| [0009](0009-no-local-dns-server.md) | No local DNS server; resolved stub stays on | Accepted | 2026-11-06 |
| [0010](0010-deploy-script-semantics.md) | Deploy: fast-forward only, preflight guards, no image pulls, no auto-rollback | Accepted | 2026-10-19 |
| [0011](0011-agent-docs-layout.md) | Agent docs: root AGENTS.md, nested per subtree, tested | Accepted | 2026-11-07 |
| [0012](0012-sops-age-secrets.md) | Secrets in SOPS with age (planned) | Proposed | 2026-11-07 |

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
