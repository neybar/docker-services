# 0010: Deploy semantics: fast-forward only, preflight guards, no image pulls, no auto-rollback

- **Status:** Accepted
- **Date:** 2026-10-19
- **Links:** PR #26 (self-hosted deploy), PR #36 (integration checks), PR #38 and PR #39 (preflight guards);
  `scripts/deploy.sh`; `docs/DEPLOY.md`; `AGENTS.md` hard rules 1 and 2; Beads `ds-cqo`, `ds-4gy`

## Context

A merge to `master` is a live deploy on orcrist: `.github/workflows/deploy.yml` runs `scripts/deploy.sh` on a
self-hosted runner, from the existing checkout (not `actions/checkout`), because that directory holds `.env` and
gitignored service data. Docker access is root on the host, so whatever merges runs as root (`docs/DEPLOY.md`).
PR #26 introduced the flow; the guards below were added later after specific failures.

## Decision

`scripts/deploy.sh`:

1. **Refuses to run** unless the checkout is on `master` with no tracked modifications. Deploys queue and never
   overlap (`concurrency: deploy-orcrist`).
2. **Fast-forwards only** (`git merge --ff-only`) to exactly `$GITHUB_SHA`, which must be on `master`. If HEAD
   already contains that commit, it exits without doing anything.
3. **Preflight guards run before any container is touched**, print what to fix, and need no rollback:
   - the live Dolt config on the NAS must match `dolt/` (`scripts/lib/dolt-nas.sh`). Origin: a stale copy "has broken
     Dolt before" (`deploy.sh` comment); PR #38.
   - NVMe data must not still be at a legacy path while its `$NVME_DIR` path is empty (`nvme_layout_check`), so
     Plex cannot come up on an empty library (PR #39, ADR 0005).
4. Runs `docker compose config --quiet`, then `docker compose up -d --build --remove-orphans`, then restarts
   Traefik if `traefik-rules/` is newer than its last start (ADR 0002).
5. **Never pulls images.** Upgrades are deliberate: `docker compose pull <service>` then `up -d`, or change the tag in
   a PR.
6. **Never resets or rolls back automatically.** A failed deploy leaves the checkout at the new commit and prints the
   commits it contained. Rollback is a revert on `master` through a PR.

## Alternatives considered

- **Automatic rollback.** The sources state the rule, and the consequence of an emergency `git reset` without a
  revert: the next deploy fast-forwards straight back to the bad commit. No evaluation of auto-rollback is recorded.
- **`actions/checkout` in the runner workspace.** Not used, because the deploy directory holds `.env` and service data
  (`docs/DEPLOY.md`).
- **Pull images on every deploy.** Not recorded as evaluated; the doc only states the deliberate-upgrade rule.

## Consequences

- `deploy.sh` runs from the deploy checkout, so a change to it takes effect on the deploy after the one that ships
  it.
- A feature branch in the deploy checkout pauses deploys, and switching it to a commit without `traefik-rules/`
  deletes the directory under the running Traefik. Agents therefore never use the deploy checkout (`AGENTS.md`).
- Guards trade availability for safety: a stale Dolt NAS copy blocks all deploys until fixed. On 2026-11-07 this
  fired falsely when authelia ran on an unmounted-directory copy (ADR 0007, `ds-4gy`).
- Plex (`VERSION=public`) still updates itself on container restart (`docs/DEPLOY.md`).
