# Incident write-ups

Blameless, factual accounts of outages and near-misses on this stack: what happened, why, and what changed. Each
links the ADRs, PRs and Beads issues that came out of it. Where a cause or a date is not known, the write-up says so
instead of guessing.

Files are named `YYYY-MM-DD-short-slug.md`. The date is the incident date; when that is not recorded, it is the date
the fix landed, and the write-up says so.

## Index

| Date | Incident | Status |
|---|---|---|
| [2026-10-03](2026-10-03-nzbhydra2-h2-on-nfs.md) | NZBHydra2 database wedged about every 9 days (fix date; first recorded June 2026) | Fixed |
| [2026-11-07](2026-11-07-home-ssd-failure-and-boot-order.md) | `/home` SSD failure and the boot-order outage | Mitigated, hardware cause open |
| [2026-11-07](2026-11-07-plex-db-not-backed-up.md) | The Plex database was never backed up (found and fixed the same day) | Fixed |

## Template

```markdown
# Title

- **Date:** YYYY-MM-DD (say what the date is if it is not the incident date)
- **Status:** Open | Mitigated | Fixed
- **Links:** ADRs, PRs, Beads issues

## Summary

Two or three sentences: what broke, why, what changed.

## Impact

Who or what was affected, and for how long.

## Timeline

Dated entries. Mark times that are not recorded.

## Root cause

What the evidence shows. Separate proven causes from suspected ones.

## What went well

## What went badly

## Follow-ups

PRs and issues, each with a link or id.

## Open questions

What is still unknown.
```

No instance data in a write-up: no addresses, hostnames other than `orcrist`, secrets, serial numbers or log
content. Use placeholders and generic names ("the NAS"). See [ADR 0001](../decisions/0001-public-private-split.md).
