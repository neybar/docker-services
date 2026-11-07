# 0007: Boot ordering: Docker requires its mounts, CIFS automounts, wait for IPv4

- **Status:** Accepted
- **Date:** 2026-11-07
- **Links:** PR #48 (boot order), PR #46 (`/home`); Beads `ds-cqo`, `ds-4gy`; `REBUILD.md` §3 and §5

## Context

On 2026-11-07 a reboot left 20 of 22 containers exited, and the cause was a boot race (`ds-cqo` records the
attribution; it first said "cause unknown"). Per `REBUILD.md` §3 and `ds-4gy`:

- `network-online.target` was reached on the interface's IPv6 address 0.24s before DHCPv4 assigned the IPv4 address,
  and the NAS is reached over IPv4. All ten CIFS mounts failed with `Network is unreachable`. It is a race, so some
  boots work.
- Docker then started anyway. Containers bound the directory underneath the unmounted `/mnt/docker`, which on this
  host is not empty: authelia came up on that old copy, and the deploy's Dolt drift check compared against it and
  refused to deploy.
- The same shape hit `/home` on 2026-11-07 (PR #46, `REBUILD.md` §5): with `/home` a separate `nofail` mount, Docker
  started first, Traefik came up with an empty `/rules`, no `chain-*@file` middleware existed, and every chained
  router returned 404.

## Decision

Host-level systemd configuration (not in the repo; templates in `REBUILD.md`):

1. `systemd-networkd-wait-online` runs with `-o routable -4` (drop-in `20-require-ipv4.conf`, sorted after netplan's
   own drop-in), so `network-online` means IPv4 is up.
2. The ten CIFS fstab lines use `_netdev,x-systemd.automount`: a mount that fails at boot is not retried, and
   automount mounts on first access.
3. `docker.service` has `RequiresMountsFor=/mnt/docker` (`wait-for-nas.conf`). A `/mnt/docker` that fails to mount
   stops Docker from starting. A `RequiresMountsFor=/home` drop-in is documented too; it is a no-op while `/home` is on `/`.

## Alternatives considered

- **Do nothing and rely on `restart: unless-stopped`.** The prior state. Not recorded as evaluated.
- **Leave Docker free to start and fix up later.** Rejected in favour of an obvious outage (Docker not starting)
  over services quietly running on empty directories (`REBUILD.md` §5).

No other options are recorded in the sources.

## Consequences

- Verified on the next boot (2026-11-07, `ds-4gy`): DHCPv4 before `network-online`, Docker started after
  `/mnt/docker`, 22 of 22 containers running, `validate-traefik.sh` 27 pass and 0 fail.
- If the NAS is down at boot, Docker does not start. That is intended.
- The drop-ins are host state, listed as "not captured" in `REBUILD.md` §1. They are in the restic backup of `/`
  (ADR 0006), not in this repo.
- `ds-cqo` closed on this attribution and says to reopen if a later reboot leaves containers exited.
