# The Plex database was never backed up

- **Date:** 2026-11-07 (found and fixed the same day; how long the gap existed is not recorded)
- **Status:** Fixed
- **Links:** [ADR 0006](../decisions/0006-restic-backs-up-whole-root.md), PRs #47, #49, #52, Beads `ds-6d1`,
  `ds-nhh.4.11`, `ds-nhh.4.16`, `REBUILD.md` §6

## Summary

The host restic backup used an include list that named `/usr/local/plex`. That path is a symlink to the Plex config on
the NVMe, and restic stores a symlink, not its target. No snapshot before `129d6c33` held the Plex library database
(about 13GB). The backup now covers all of `/` minus regenerable paths, and a restore was tested.

## Impact

None materialised: no data was lost. Had the NVMe failed, Plex would have restarted with an empty library (watch
history, collections, ratings and metadata gone). The gap was open for the life of the include list; its start is not
recorded.

## Timeline

- Before 2026-11-07: the backup runs daily with an include list naming `/usr/local/plex`. `ds-6d1` is open to archive
  the Plex databases with a task-scheduler job, on the understanding that they are in no backup.
- 2026-11-07: while restoring `/home` after the SSD failure
  ([incident](2026-11-07-home-ssd-failure-and-boot-order.md)), the include list is found to name a symlink. `restic ls`
  confirms the Plex database is not in the snapshots. PR #47 documents it.
- 2026-11-07: the include list is replaced with `/` plus excludes. First snapshot `129d6c33`; `restic ls` shows the
  Plex `Databases` directory present (PR #49). `ds-6d1` is closed as unnecessary.
- 2026-11-07: a test restore from `latest` (snapshot `f5c09f96`) succeeds and `restic check` is clean (PR #52,
  `ds-nhh.4.11`). A Plex `integrity_check` on the restored pair returns `ok` (PR #54, `ds-nhh.4.16`).

## Root cause

An include-list backup lets a path be listed without being covered: a symlink in the list is backed up as a link. The
restic exit code and snapshot success said nothing about whether the target was present. The gap was found on
2026-11-07, when snapshot contents were listed during the restore.

## What went well

- The gap was found by a real restore, before a real loss.
- Backing up `/` removes the class of error: every real path is under it, and new host files are covered without
  editing a list.
- The first snapshot after the change was checked with `restic ls`, and a restore plus an integrity check followed on
  the same day.

## What went badly

- The backup ran with a silent gap, and its success was judged by exit code.
- `ds-6d1` proposed a separate archive job; the symlink cause was found only afterwards.
- Before 2026-11-07 no restore had ever been tested (`ds-nhh.4.11`).
- The live Plex files are read while Plex runs and may be inconsistent. Plex's own dated copies, written every 3 days,
  are the safe restore source.

## Follow-ups

- PR #49 and [ADR 0006](../decisions/0006-restic-backs-up-whole-root.md): whole-root backup with a package manifest.
- PR #52 (`ds-nhh.4.11`): test restore. Plex integrity check: PR #54 and `ds-nhh.4.16`.
- `ds-nhh.4.10`: a full DR drill from a fresh VM, still open.
- Lesson recorded in `REBUILD.md` §6: check a backup by listing or restoring it, not by exit code; use
  `restic diff` to spot directories dropping out of snapshots.

## Open questions

- How long the Plex database had been missing from the backup: the include list's history is not in the repo (it is
  host config).
- Whether any other symlink in the old include list hid a second gap: not recorded.
