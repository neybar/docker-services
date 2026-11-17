# Daily restic backup failed while the NAS was not answering

- **Date:** 2026-11-17
- **Status:** Mitigated. The unit retries a failed run; why the NAS stopped answering is unknown
- **Links:** `REBUILD.md` §6, Beads `ds-nhh.4.7.1`, PR #71

## Summary

The daily host backup failed at 03:44 America/Denver because the NAS stopped answering for about three minutes.
`/usr/local/sbin/restic-backup` exits when `/mnt/backups` is not mounted, so restic never started and its own retries
did not run. A systemd drop-in now restarts the unit on failure. The failure notification fires only after those
retries are used up.

## Impact

The 2026-11-17 backup did not run. No host data was lost. The runs of 2026-11-12 through 2026-11-16 had finished
successfully, and `/mnt/backups` was mounted again once the NAS answered. Nothing else is recorded as affected.

## Timeline

- 2026-11-12 through 2026-11-16: the daily backup finishes successfully.
- 2026-11-17, about 03:41 America/Denver: the NAS stops answering. It is back about three minutes later. The NAS-side
  cause is not known.
- 2026-11-17, 03:43:57 America/Denver: the kernel logs a CIFS timeout (no response for 180 seconds). NFS reports the
  server not responding until 03:44:16, when the NAS answers again.
- 2026-11-17, 03:44 America/Denver: `restic-backup.service` runs in that window and exits because `/mnt/backups` is
  not mounted.
- 2026-11-17: drop-in `/etc/systemd/system/restic-backup.service.d/override.conf` is installed (`Restart=on-failure`,
  `RestartSec=10min`, `StartLimitIntervalSec=2h`, `StartLimitBurst=4`) and checked with `systemctl show`.

## Root cause

Two separate facts, both from the orcrist journal:

1. The NAS did not answer for about three minutes. The kernel logged a CIFS timeout of 180 seconds and NFS "server
   not responding" over the same window. Why the NAS stalled is not known.
2. The backup script treats a missing `/mnt/backups` as fatal and exits before invoking restic. A mount that is only
   briefly down therefore fails the run, and restic's own retries never start. With no `Restart=` on the unit, that
   single exit ended the attempt. The failure notification (`OnFailure`) had no retries to wait out, so it ran with
   the first exit.

The drop-in does not change the script. It restarts the unit, at most four starts in two hours and ten minutes
apart. `OnFailure` (the notify unit) runs only once systemd refuses another restart, so a stall shorter than the
retry window does not notify, and a mount that stays down still does.

## What went well

- The previous four daily runs succeeded, so this was a short NAS stall and not a broken backup configuration.
- The mount recovered on its own; the repository was reachable again the same day.
- The retry drop-in was installed and verified the same day.

## What went badly

- A three-minute NAS stall was enough to skip the daily backup, because the script exits before restic can retry.
- The unit did not restart, so the failure notification ran on the first exit instead of after a retry window.

## Follow-ups

- PR #71: `REBUILD.md` §6 records the live drop-in and how to install it on a rebuild.
- Beads `ds-nhh.4.7.1`: add the drop-in to the Ansible restic role so a rebuild keeps it.

## Open questions

- Why the NAS stopped answering for about three minutes. Not investigated here.
- Whether the 2026-11-17 run was started again by hand after the mount recovered: not recorded.
