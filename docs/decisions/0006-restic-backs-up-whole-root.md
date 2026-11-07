# 0006: restic backs up all of `/` minus regenerable paths

- **Status:** Accepted
- **Date:** 2026-11-07
- **Links:** PR #49; Beads `ds-6d1` (closed), `ds-nhh.4.11` (test restore, PR #52); `REBUILD.md` §6;
  PR #47 (the host backup first documented)

## Context

The host backup used an include list. `$NVME_DIR/plex/config` (the Plex library database, about 13GB) was in no
backup: the include list named `/usr/local/plex`, a symlink to it, and restic stores a symlink, not its target. No
snapshot before `129d6c33` has the Plex DB (`REBUILD.md` §6). `ds-6d1` proposed a task-scheduler job to archive the
Plex databases.

## Decision

1. The host backup covers all of `/` (one filesystem, `--one-file-system`) plus `/boot/efi`, minus an exclude list
   (`/etc/restic/excludes`) of regenerable paths: `/var/lib/docker`, `/var/lib/containerd`, snap, caches, temp,
   journal, the swap file, and Plex's `Cache`, `Codecs`, `Crash Reports`, `Diagnostics`, `Drivers`, `Logs` and
   `Updates`. Plex `Metadata` and `Media` stay in, because custom artwork would be lost.
2. Container images are not backed up. A manifest is: `restic-backup` writes `dpkg-selections.txt`, `apt-manual.txt`,
   `snap-list.txt` and `docker-images.txt` into `/var/lib/restic-backup/manifest/` before each run, and the manifest
   is in the snapshot.
3. Retention is 14 daily, 8 weekly, 12 monthly, with `forget --group-by host,tags`. The reason for `--group-by` is not recorded in the repo or in Beads.
4. Live Dolt data is excluded (not crash-consistent). A host cron writes a Dolt snapshot to the NAS, and restic keeps
   dated generations of that directory.
5. NAS paths are backed up only when listed by themselves, because of `--one-file-system`.

## Alternatives considered

- **A task-scheduler job to copy Plex's `Databases/`** (`ds-6d1`). Closed as unnecessary: the whole-root backup
  includes the database and Plex's own dated consistent copies, which are in snapshot `129d6c33` and every later one.
- **Extend the include list.** The prior approach; the symlink gap above is its failure mode. Backing up `/` means
  every real path is under it.

## Consequences

- New host files are covered without editing a list. This includes host files not captured in the repo (crontab,
  systemd drop-ins, `/etc/restic/`).
- The Plex and NZBHydra2 files are read live and may be inconsistent; Plex's dated copies are the safe restore
  source (`REBUILD.md` §6).
- A restore was tested on 2026-11-07 (snapshot `f5c09f96`, `restic check` clean; `ds-nhh.4.11`).
- restic 0.16.4 has no `--overwrite`; restores run as root to keep ownership (`REBUILD.md` §6).
- Restores need the NAS: the repo is on `/mnt/backups`. The repo password file sits on the NAS next to the repository
  (`REBUILD.md` §1); `ds-nhh.3` (ADR 0012, Proposed) lists that file among the host secrets to bring under SOPS.
