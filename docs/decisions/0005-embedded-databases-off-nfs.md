# 0005: Embedded databases live on local NVMe, not NFS

- **Status:** Accepted
- **Date:** 2026-10-03
- **Links:** PR #19 (NZBHydra2 H2 off NFS); PR #39 (the `$NVME_DIR` layout); `AGENTS.md` hard rule 9;
  `REBUILD.md` §5; `scripts/lib/nvme-paths.sh`; `scripts/ci/test-nvme-paths.sh`; h2database#1954

## Context

Service configs and media live on a Synology NAS, which containers reach over NFS. NZBHydra2's H2 database wedged
roughly every 9 days and needed a container restart. PR #19 traced it (commit message and `REBUILD.md` §5):

1. The Synology periodically revokes NFSv4 lock state; the kernel logs `NFS: : lost 3 locks` (15 events June to
   September 2026).
2. The kernel does not reclaim it (`recover_lost_locks` is off by default), so the application sees `EIO`. `hard`,
   `timeo` and `retrans` only cover timeouts.
3. H2 treats any I/O error as fatal and never reopens its file. Upstream treats this as by design (h2database#1954,
   open since 2019).

SQLite-based services survive because they reopen and retry (`REBUILD.md` §5).

## Decision

1. No embedded random-access database (H2 and the like) on NFS. Such data goes on local NVMe.
2. All NVMe state sits under `$NVME_DIR/<service>/<role>` (default `/usr/local/docker`, on `/`). `$NVME_DIR` is not
   `LOCALDOCKERDIR`, the repo checkout under `/home`. PR #39 moved Plex, NZBHydra2 and Dolt from scattered
   `/usr/local` and `/tmp` paths into it.
3. `NVME_PATHS` in `scripts/lib/nvme-paths.sh` is the single table; `scripts/ci/test-nvme-paths.sh` fails when
   compose's mounts disagree with it.
4. NZBHydra2's database path is not configurable, so only `/config/database` is a nested local mount inside the NFS
   `/config`. `stop_grace_period: 120s` lets H2 compact on shutdown.

## Alternatives considered

- **`hard`/`timeo`/`retrans` mount options.** Do not help (above).
- **Restart on failure.** The prior state; not recorded as evaluated further.
- **Fix H2.** Upstream will not (h2database#1954).

## Consequences

- An empty local path starts a healthy-looking, empty service, because Docker auto-creates missing bind sources.
  `deploy.sh` therefore refuses to deploy while data sits at a legacy path and its `$NVME_DIR` path is empty
  (`nvme_layout_check`); `scripts/migrate-nvme-layout.sh` does the move (ADR 0010).
- Local data needs its own backup; it is covered by restic (ADR 0006).
- A new NVMe service needs a row in `NVME_PATHS` (`AGENTS.md`, "Adding a service").
