# `/home` SSD failure and the boot-order outage

- **Date:** 2026-11-07 (the SSD errors began 2026-10-31; an earlier drive in the same bay failed 2026-10-17)
- **Status:** Mitigated. The bay is retired; the hardware cause is unknown
- **Links:** [ADR 0007](../decisions/0007-boot-ordering.md), PRs #46, #47, #48, Beads `ds-cqo`, `ds-4gy`,
  `REBUILD.md` §3 and §5

## Summary

The SSD holding `/home` failed to mount at boot (ext4 group descriptors corrupted). `/home` was recreated, restored
from restic and then moved onto the NVMe. Separately, Docker started before `/home` and then before the NAS mounts,
so containers ran on empty or stale directories. Boot-ordering drop-ins fixed that. Why two SSDs failed in the same
bay is not known.

## Impact

- Key-based SSH was locked out until the SSH directory was copied from a rescue copy onto the root disk, because
  `authorized_keys` lived in `/home`.
- After the `/home` boot, Traefik had an empty `/rules`, no `chain-*@file` middleware existed, and every chained
  router returned 404.
- The Actions runner and the Minecraft manager failed with "Dependency failed", so the deploy for PR #46 sat queued.
- After a later reboot, 20 of 22 containers stayed exited; authelia ran on a stale copy under the unmounted
  `/mnt/docker`, and the deploy refused to run on a false Dolt drift.

Durations are not recorded.

## Timeline

- 2026-10-03: the first `/home` disk (a Samsung 870) is found throwing media errors.
- 2026-10-17: it is replaced by a 1TB T-Force SATA SSD with a fresh ext4 filesystem.
- 2026-10-31 to 2026-11-06: the T-Force logs read errors and ext4 checksum errors (297 on 2026-11-06) while its own
  SMART stays clean.
- 2026-11-06: a SMART extended self-test passes (no errors, no reallocated or pending sectors, no CRC errors). A
  memory test is started and stops after 3 of 6 loops, 0 failures.
- 2026-11-07, boot 1: `/home` fails to mount. A read-only `e2fsck` aborts on bad metadata across many groups. The
  filesystem is recreated and `/home` is restored from the 2026-11-06 restic snapshot. The first restore ran as a
  normal user and flattened ownership; a root restore with `--verify` fixed it.
- 2026-11-07: containers had started before `/home` mounted; Traefik and CrowdSec are force-recreated and the
  validation scripts pass. A `RequiresMountsFor=/home` drop-in is added.
- 2026-11-07: `/home` is copied to the NVMe root filesystem and the SATA bay is retired (PR #47). PR #46 documents the
  drop-in.
- 2026-11-07, boot 2 (reboot at about 02:44 UTC): only 2 of 22 containers return (`ds-cqo`). All ten CIFS mounts had
  failed with `Network is unreachable`: `network-online.target` was reached on the IPv6 address 0.24s before DHCPv4.
- 2026-11-07: wait-online `-4`, CIFS automount and `RequiresMountsFor=/mnt/docker` are installed (PR #48).
- 2026-11-07, boot 3 (about 03:20 UTC): DHCPv4 first, Docker after `/mnt/docker`, 22 of 22 containers running,
  `validate-traefik.sh` 27 pass and 0 fail (`ds-4gy`).

## Root cause

Two separate causes.

**Boot ordering (understood).** Docker had no dependency on the mounts it needs. With `/home` a separate `nofail`
mount, Docker started first and bind-mounted the empty directory underneath; with the CIFS mounts failing, it did the
same for `/mnt/docker`, which on this host is not empty. The CIFS failure was a race (IPv6 `network-online` before
DHCPv4), so some boots worked. `ds-cqo` first recorded "cause unknown" for the exited containers; the boot-order
attribution is supported by the fix working on the next boot, and the issue says to reopen if a reboot leaves
containers exited.

**SSD failure (unknown).** The T-Force's SMART data is clean, and the drive reports no I/O or ata errors of its own,
so the kernel's media and checksum errors are not seen by the drive. The suspects are non-ECC RAM, or the bay's
data/power path (the ASRock 4X4 BOX-4000 uses a proprietary flat SATA data and power cable and has no other port), or
the controller. None is proven. The handoff notes also list a bad copy when `/home` moved to this drive, and an unclean
shutdown.

## What went well

- Daily restic snapshots had `/home`; the 2026-11-06 snapshot restored cleanly (172,980 files verified).
- The checkout and its gitignored state were in that snapshot, and the stack was recovered the same day.
- `RequiresMountsFor` turns a missing mount into an obvious outage (Docker does not start) instead of services
  quietly running on empty directories.
- The fix was verified on the next boot against recorded criteria (`ds-4gy`).

## What went badly

- `/home` had fsck pass 0, so ext4 errors accumulated unattended.
- Two drives failed in the same bay within three weeks, and the first drive logged kernel read errors in the journal from
  February 2026 and was replaced 2026-10-17.
- `authorized_keys` lived on a disk that could fail to mount, which removed key-based SSH.
- A first restore ran without root and lost ownership.
- A repo (`Projects/dotfiles`) vanished from `/home` between 2026-11-04 and 2026-11-05 and dropped out of later
  snapshots without anyone noticing; it was restored from the 2026-11-04 snapshot.
- The startup cleanup in task-scheduler races `docker compose up` (it pruned a container mid-start); noted in the
  handoff, no issue id was found.

## Follow-ups

- PR #46: Docker waits for `/home`.
- PR #47: `/home` on the NVMe, the SATA bay retired, restic restore notes.
- PR #48 and [ADR 0007](../decisions/0007-boot-ordering.md): wait for IPv4, CIFS automount, Docker requires
  `/mnt/docker`.
- `ds-cqo` and `ds-4gy` closed on the verified boot.
- Suggested in the handoff notes, not confirmed done: move `AuthorizedKeysFile` outside `/home`, finish the memtest,
  decide whether to replace the bay cable.

## Open questions

- What corrupted the T-Force filesystem. Cable, bay, RAM, controller and an unclean shutdown are not ruled out.
- Whether the Samsung and the T-Force failures share a cause. Same bay is the only link found.
- What deleted `Projects/dotfiles` between 2026-11-04 and 2026-11-05. The user says they did not.
- Whether the memory test would have passed: it stopped at 3 of about 6 loops.
- Times for the first two boots, and how long each outage lasted: not recorded.
