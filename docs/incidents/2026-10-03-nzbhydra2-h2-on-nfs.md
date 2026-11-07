# NZBHydra2 database wedged about every 9 days

- **Date:** 2026-10-03 (the date the fix, PR #19, merged; the outages ran from at least June 2026)
- **Status:** Fixed for NZBHydra2; the NAS-side cause is not fixed
- **Links:** [ADR 0005](../decisions/0005-embedded-databases-off-nfs.md), PR #19, PR #39, `REBUILD.md` §5,
  [h2database#1954](https://github.com/h2database/h2database/issues/1954)

## Summary

NZBHydra2's H2 database stopped working roughly every 9 days and only a container restart cleared it. The NAS
periodically drops NFSv4 lock state, the kernel passes that to the application as `EIO`, and H2 never recovers from an
I/O error. The database moved to local NVMe; the lock loss itself still happens.

## Impact

NZBHydra2 searches failed until someone restarted the container. The September outage ran about two weeks undetected.
Other services were not affected.

## Timeline

- June 2026 (5, 6 and 8 June): three recorded outages. Their dates match three lock-loss events in the kernel log.
- 2026-09-18, 16:16 UTC: last successful write to the database file.
- 2026-09-18, 16:31 UTC: the kernel logs `NFS: : lost 3 locks`.
- 2026-09-18, 16:42 UTC: first `MVStoreException`. Failures continued for about two weeks.
- 2026-10-03: root cause traced; PR #19 moves the database to NVMe.

Between June and September the kernel logged 15 lock-loss events.

## Root cause

Each link was checked against primary evidence (PR #19):

1. The NAS periodically revokes NFSv4 lock state. All NFS mounts share one TCP transport, so it affects every mount.
2. Linux does not reclaim lost locks by default (`recover_lost_locks` is off; the kernel documents recovery as a
   data-corruption risk), so the application gets `EIO`. `hard`, `timeo` and `retrans` cover only timeouts.
3. H2 treats the I/O error as fatal, does not retry or reopen the file, and keeps it locked for the store's lifetime.
   Upstream considers this by design (h2database#1954, open since 2019).
4. NZBHydra2's 40-connection pool keeps the dead store in use.

The database file itself was intact: it read back completely from the host and from inside the container.

SQLite-based services on the same storage (Sonarr, Radarr, LazyLibrarian) reopen and retry, so they survived.

## What went well

- The cause was traced to evidence at each step rather than assumed, and the earlier "transient NFS I/O" theory was
  replaced.
- The correlation between kernel lock-loss events and outage dates held for the June and September incidents.
- The fix targets only the database directory; config, logs and backups stay on the NAS.

## What went badly

- The outage recurred from at least June to October before the cause was found. Retention caps set in June bounded
  database size but did not prevent it.
- The September failure ran about two weeks with no alert.
- The fix makes NZBHydra2 immune but does not stop the lock loss, which still exposes other NFS-backed services.

## Follow-ups

- PR #19: nested NVMe mount at `/config/database`, `stop_grace_period: 120s` (H2 compacts on shutdown).
- [ADR 0005](../decisions/0005-embedded-databases-off-nfs.md) and `AGENTS.md` hard rule 9: no embedded random-access
  database on NFS.
- PR #39: the `$NVME_DIR` layout and `NVME_PATHS` table, with a CI check against compose.
- The database path was chosen on the NVMe, not `/home`, because the `/home` disk was already failing (see
  [the SSD incident](2026-11-07-home-ssd-failure-and-boot-order.md)).
- A healthcheck for NZBHydra2 was suggested in PR #19. This write-up found no issue id for it.

## Open questions

- Why the NAS drops lock state about every 9 days. PR #19 notes it needs DSM-side investigation; no result is
  recorded.
- Whether a healthcheck was ever added: not recorded in the sources read.
