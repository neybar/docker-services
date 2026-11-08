# Rebuilding This Homelab

Everything needed to bring this stack up on a fresh host. The goal is that a
rebuild needs **no verbal instructions** — if you find yourself guessing, that
is a bug in this document, so fix it here.

Read alongside `README.md` (services, networks, variables), `env.example` and `docs/CROWDSEC.md` / `dolt/README.md`
(subsystem details). Rules for agents are in `AGENTS.md`.

---

## 1. What is NOT in this repo

Start here, because these are the things a fresh host will not have and
`docker compose up` will not create. This is the current honest gap list.

| Thing | Where it lives | Status |
|---|---|---|
| 10 CIFS mounts (`/mnt/*`) | `/etc/fstab` | **not captured** — template below |
| CIFS credentials | `/etc/cifspwd` (root, `0600`) | **secret, never commit**. `.env` and every other secret: where each lives and how to regenerate it is in `secrets/INVENTORY.md` in the private `homelab-site` repo |
| Plex library database | `$NVME_DIR/plex/config` (13GB) | **not backed up anywhere** — see §6 |
| Minecraft manager | separate repo at `~/games` | own git repo, no remote |
| Dolt backup cron | jalance's crontab | **not captured**: `CRON_TZ=America/Denver` and `0 3 * * * /home/jalance/Projects/docker-services/scripts/dolt-prebackup.sh >> /home/jalance/.local/state/dolt-prebackup.log 2>&1` (`mkdir -p ~/.local/state` first; jalance is in the `docker` group). Not in task-scheduler: the script needs `docker exec`, and socket-proxy has `EXEC` off on purpose (it would let every socket-proxy client exec into every container) |
| Docker waits for `/home` | `/etc/systemd/system/docker.service.d/wait-for-home.conf` | **not captured**: template in §5 (`/home disk`) |
| Host backup (restic) | `/etc/restic/`, `/usr/local/sbin/restic-backup`, `restic-{backup,check}.{service,timer}`, `restic-notify@.service` in `/etc/systemd/system/` | **not captured**: what it covers and how to restore are in §6. The repo password file is on the NAS next to the repository, never in this repo. Because restic backs up all of `/`, the uncaptured host files in this table (crontab, drop-ins, `/etc/restic/` itself) are in every snapshot |
| Dolt live config | `/mnt/docker/dolt/{servercfg,init}` (NAS) | templates in `dolt/`; copied by hand, not deployed by a merge (public repo). `certs/` is written by `dolt-certs.sh`, `backups/` by the cron above |
| DDNS for `home.<domain>` (A record; the `*` wildcard CNAMEs to it) | UniFi gateway → Dynamic DNS, service Cloudflare | **not captured** — uses its own "Edit zone DNS" token (the 2020 one, rolled 2026-10-20), separate from Traefik's `CLOUDFLARE_DNS_API_TOKEN`. Namecheap/DNS-O-Matic entries were removed (Cloudflare is authoritative). A new host keeps the same WAN IP only if the gateway stays |

---

## 2. Host prerequisites

Verified against the current host:

- Ubuntu 24.04 LTS
- Docker 29.x with Compose v5 (`docker compose`, not `docker-compose`)
- Packages: `cifs-utils` (required for the mounts), `git`
- Useful for diagnostics, not required to run the stack: `smartmontools`,
  `sqlite3` — both were missing on this host when they were first needed
- A user whose `uid:gid` matches `PUID`/`PGID` in `.env` (currently `1026:100`)

### Host DNS: leave systemd-resolved at its defaults

NextDNS serves live DNS; there
is no local DNS server in the stack. Keep `/etc/systemd/resolved.conf` at the
Ubuntu defaults, with the stub listener on (`127.0.0.53:53`): Tailscale manages
the host's DNS through systemd-resolved. With `DNSStubListener=no` (once needed
because Pi-hole held `:53`) local lookups failed. Nothing in compose may publish
`:53`.

---

## 3. Synology mounts

The NAS is `$NAS_IP` (in `.env`). Ten CIFS shares are mounted on the host; service
configs and all media live on them. Create `/etc/cifspwd` first:

```
# /etc/cifspwd  — chmod 600, owned by root
username=<user>
password=<password>
```

Then one `/etc/fstab` line per share, all using the same options:

```
//<nas-ip>/<share> /mnt/<share> cifs _netdev,x-systemd.automount,user,vers=3.0,uid=jalance,gid=users,rw,suid,nobrl,file_mode=0600,dir_mode=0700,credentials=/etc/cifspwd 0 0
```

Shares: `audiobooks` `backups` `docker` `downloads` `ebooks` `music` `photo`
`software` `video` `web`

`nobrl` matters — it disables byte-range locking, which is what lets SQLite
work at all over CIFS. Do not drop it.

`_netdev,x-systemd.automount` matter too: a mount that fails at boot is not
retried, and automount mounts the share on first access instead.

### Boot order: wait for IPv4, then the NAS

On 2026-11-07 all ten mounts failed at boot with `mount error(101): Network is
unreachable`. `network-online.target` was reached on enp2s0f0's IPv6 address,
0.24s before DHCPv4 gave it its LAN address, and the NAS is reached over IPv4.
It is a race, so some boots mount fine. Two drop-ins fix it; netplan's own
drop-in is `/run/.../10-netplan.conf`, so the wait-online one must sort after it:

```
sudo mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
printf '[Service]\nExecStart=\nExecStart=/lib/systemd/systemd-networkd-wait-online -i enp2s0f0 -o routable -4\n' |
  sudo tee /etc/systemd/system/systemd-networkd-wait-online.service.d/20-require-ipv4.conf
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/mnt/docker\n' |
  sudo tee /etc/systemd/system/docker.service.d/wait-for-nas.conf
sudo systemctl daemon-reload
systemctl show docker -p RequiresMountsFor   # includes /mnt/docker
```

Replace `enp2s0f0` with the new host's LAN interface. Without the Docker
drop-in, containers start on the directory underneath an unmounted
`/mnt/docker`, which on this host is not empty: authelia came up on that old
copy, and the deploy's Dolt drift check compared against it and refused to
deploy. With it, a `/mnt/docker` that fails to mount stops Docker from
starting. After a boot, `journalctl -b | grep -E 'DHCPv4|network-online'`
should show the DHCPv4 line first.

Note the containers reach the same Synology paths over **NFS** via Docker
volume `driver_opts`, independently of these host CIFS mounts. Both protocols
touch the same files; see §5 for why that matters.

---

## 4. Docker networks

`socket_proxy` and `t2_proxy` are external and must exist before first run:

```bash
docker network create --gateway 192.168.90.1 --subnet 192.168.90.0/24 t2_proxy
docker network create --gateway 192.168.91.1 --subnet 192.168.91.0/24 socket_proxy
```

---

## 5. Local NVMe paths — read before restoring

Docker **auto-creates** a missing bind-mount source directory as `root:root`,
and LinuxServer images then `lsiown -R abc:abc /config` on startup. So these
paths self-bootstrap: the stack will come up cleanly without them existing.

That is the trap. A service whose local path is empty starts **fresh**, and
looks healthy while doing it.

Every service that needs the NVMe lives under one parent, `$NVME_DIR/<service>/<role>`. `NVME_DIR` is optional in
`.env`; compose defaults it to `/usr/local/docker`, which is on `/` (the NVMe). It is **not** `LOCALDOCKERDIR`, the
repo checkout under `/home` (below). The list is `NVME_PATHS` in `scripts/lib/nvme-paths.sh`;
`scripts/ci/test-nvme-paths.sh` fails if compose's mounts disagree with it.

| Path | Holds | If empty on rebuild |
|---|---|---|
| `$NVME_DIR/plex/config` (`/config`) | Plex library DB (13GB) | **watch history, collections, ratings and metadata all gone** |
| `$NVME_DIR/plex/transcode` (`/transcode`) | transcode scratch, local for speed | nothing — intentionally ephemeral |
| `$NVME_DIR/nzbhydra2/database` (`/config/database`, nested inside the NFS `/config`) | NZBHydra2 H2 database (98MB) | search history and stats lost; config is safe in `nzbhydra.yml` on NFS |
| `$NVME_DIR/dolt/data` | Dolt databases (Beads) and users, at `/var/lib/dolt` | **every Beads project is gone**, and init recreates only the `beads` users, until restored from `/mnt/docker/dolt/backups` (`dolt/RESTORE.md`) |
| `$LOCALDOCKERDIR/crowdsec/{config,data}` | CrowdSec config + SQLite DB | nothing irreplaceable — regenerated on first start; ban decisions and alert history are lost (CAPI blocklist re-syncs) |
| `$LOCALDOCKERDIR/traefik-logs` | Traefik access log (`access.log`, current file + 2 rotated `access.log.<timestamp>`; dir mode 700) | nothing — log history only |

Restore `$NVME_DIR/plex/config` from backup **before** first `up -d`, or Plex will
initialise an empty library.

### Legacy paths (before the `$NVME_DIR` layout)

The NVMe data used to live at `/usr/local/plex`, `/tmp/plex_transcode`, `/usr/local/nzbhydra2/database` and
`/usr/local/dolt/data`. `scripts/migrate-nvme-layout.sh` moves them (a rename: same filesystem) and leaves a symlink
at each legacy path; `/tmp/plex_transcode` is not moved, its replacement is created empty. Without arguments it is a
dry run that prints each move, its size and owner; `sudo ./scripts/migrate-nvme-layout.sh --apply` does it (stops and
restarts plex, hydra and dolt; refuses if a target is non-empty; never deletes). It is idempotent.
`deploy.sh` refuses to deploy while a legacy path still holds real data and its `$NVME_DIR` path is missing or
empty (`nvme_layout_check` in `scripts/lib/nvme-paths.sh`), so Plex cannot come up on an empty library that way.
Restoring onto a host that still has only legacy paths: restore to the legacy path, then run the migrate script,
or restore straight to the `$NVME_DIR` path.

### Why these are local and not on the NAS

Embedded databases that do random-access reads do not survive network
filesystems here. The Synology periodically revokes NFSv4 lock state — the
kernel logs `NFS: : lost 3 locks` (in `dmesg`), roughly every 9 days — and with
`recover_lost_locks` off by default (the kernel calls recovery a
data-corruption risk) that surfaces to the application as `EIO`. `hard`,
`timeo` and `retrans` do not help; they only cover timeouts.

H2 treats any I/O error as fatal, never reopens its file handle, and stays
broken until the process restarts
([h2database#1954](https://github.com/h2database/h2database/issues/1954), open
since 2019). SQLite-based services survive because they reopen and retry.
So one NFS blip wedges NZBHydra2's database until the container restarts.

NZBHydra2's database path is not independently configurable (H2's URL is
`${nzbhydra.dataFolder}/database/nzbhydra`), hence the nested bind mount: only
`/config/database` is local, config/logs/backups stay on the NAS.
`stop_grace_period: 120s` is required so H2 can compact on shutdown.

### /home disk

`/home` is a plain directory on the NVMe root filesystem, not a separate mount.
The 2.5" SATA bay is retired:

- 2026-10-17: the Samsung 870 EVO in the bay failed (957 reallocated sectors,
  15k+ uncorrectable errors, eventually refusing writes). Replaced by a 1TB
  TeamGroup T-Force Vulcan Z.
- 2026-10-31 to 2026-11-06: the T-Force logged read errors and ext4 checksum
  errors, while its own SMART stayed clean.
- 2026-11-07: its filesystem failed to mount (ext4 group descriptors
  corrupted). It was recreated, restored from restic (§6), then copied to the
  NVMe with `rsync -aHAX --delete` and the `/home` line in `/etc/fstab` was
  commented out (with a note saying why).

Two drives failing in the same bay within three weeks points at the bay's path
(the ASRock 4X4 BOX-4000 uses a proprietary flat SATA data+power cable, and
there is no second port) or at RAM; neither is proven. Do not put `/home` back
on that bay until the cable is replaced and a memtest completes. The T-Force
(label `home`) is still installed and unmounted.

`LOCALDOCKERDIR` resolves to `/home/jalance/Projects/docker-services`, so the
bind mounts in `docker-compose.yml` (`traefik-rules/`, `crowdsec-config/`,
`acme/`, `crowdsec/`, …) come from `/home`. Also under `/home`: the GitHub
Actions runner (`actions-runner/`, which runs every deploy) and the Minecraft
manager (`~/games`).

#### If `/home` is ever a separate mount again

With `nofail` in fstab, Docker can start before `/home` mounts. Containers bind
the empty directory underneath and keep it after `/home` appears: on 2026-11-07
Traefik came up with an empty `/rules`, no `chain-*@file` middlewares existed,
and every chained router returned 404. The runner and the Minecraft manager
(their `WorkingDirectory` is under `/home`) failed with "Dependency failed", so
deploys sat queued. This drop-in, installed on orcrist, makes Docker wait (with
`/home` on `/` it is a no-op; the `/mnt/docker` one is in §3):

```
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/home\n' |
  sudo tee /etc/systemd/system/docker.service.d/wait-for-home.conf
sudo systemctl daemon-reload
systemctl show docker -p RequiresMountsFor   # RequiresMountsFor=/home
```

With it, a `/home` that fails to mount stops Docker from starting (an obvious
outage instead of services on empty directories). If containers did start
without `/home`, recreate the ones with `/home` bind mounts once it is mounted:
`docker compose up -d --force-recreate traefik crowdsec`. To look at the
directory a mount is hiding: `sudo mount --bind / /mnt/rootfs`, then
`/mnt/rootfs/home`.

---

## 6. Backups — what is covered and what is not

| Data | Location | Backed up? |
|---|---|---|
| Service configs | `/mnt/docker/<service>/` (NAS) | yes, Synology handles it |
| Media libraries | NAS shares | yes |
| This repo | GitHub | yes |
| Host: all of `/` (one filesystem) plus `/boot/efi`, minus what a fresh install or `docker pull` gives back (below) | restic repo `/mnt/backups/restic-orcrist` (NAS, CIFS) | yes, daily 03:30 America/Denver; keeps 14 daily, 8 weekly, 12 monthly (`--group-by host,tags`); `restic check` Sundays 05:00. Covers `/home` (with the repo checkout's gitignored `.env`, `acme/`, `crowdsec/`), `/etc`, `/root`, `/usr/local` (all of `$NVME_DIR`), `/var/spool/cron`, `/var/lib/tailscale` |
| Package manifest | `/var/lib/restic-backup/manifest/` | yes, in restic: `restic-backup` writes `dpkg-selections.txt`, `apt-manual.txt`, `snap-list.txt` and `docker-images.txt` before each run |
| Minecraft worlds | `/mnt/backups/minecraft-rescue-*` | manual snapshot, 2026-10-03 |
| Plex library DB | `$NVME_DIR/plex/config` | yes, in restic (see below) |
| NZBHydra2 H2 DB | `$NVME_DIR/nzbhydra2/database` | yes, in restic, read live (may not be consistent; history only) |
| Dolt (Beads) data | `$NVME_DIR/dolt/data` (local NVMe) | the live directory is excluded (not crash-consistent). jalance's 03:00 crontab (§1) writes a snapshot to `/mnt/docker/dolt/backups` (NAS), and restic, at 03:30, keeps dated generations of that directory |
| Dolt config | `/mnt/docker/dolt/{servercfg,init}` (NAS) | yes, Synology; templates in `dolt/` |

### Restoring from restic

Used for real on 2026-11-07 (restic 0.16.4):

- `/mnt/backups` must be mounted first; the backup service refuses to run
  without it. Load the environment: `sudo bash -c 'set -a; . /etc/restic/orcrist.env; restic snapshots'`.
- Restore **as root**. A restore run as your user writes every file as your
  user, which flattens ownership (container state such as `crowdsec/` and
  `acme/` is not owned by jalance). The fix was re-running it with sudo:
  `restic restore <snap>:/home --target /home --verify`.
- 0.16.4 has no `--overwrite` (0.17+).
- Check that the directory you need is in the snapshot before trusting it:
  `restic diff <older> <newer>` shows what disappeared between snapshots. A
  repo deleted from `/home` quietly drops out of later snapshots
  (`Projects/dotfiles` was missing from every snapshot after 2026-11-04, cause
  unknown).
- restic stores a symlink, not its target. Until 2026-11-07 the include list
  named `/usr/local/plex` (a link to `$NVME_DIR/plex/config`), so no snapshot
  before `129d6c33` has the Plex DB. Backing up `/` avoids this: every real
  path is under it.
- `--one-file-system` keeps the NAS mounts out of `/`. A NAS path is backed up
  only when listed by itself (`/mnt/docker/dolt/backups`).

Restore last tested: 2026-11-07, snapshot `f5c09f96` (`restic restore latest`
with `--include` for the Plex `Databases` dir, `nzbhydra2/database`,
`/mnt/docker/dolt/backups`, `/etc/restic`, the jalance crontab and
`/var/lib/tailscale`, into a scratch dir on `/`). 3.4 GiB in about 70s; all
paths present, the Dolt `native/ds` generation non-empty, `restic check` clean.
`PRAGMA integrity_check` returned `ok` for the newest dated `library.db` and
`library.blobs.db` pair. Stock `sqlite3` cannot open these (custom tokenizer and
collations); use Plex's own SQLite from a throwaway container with only the
scratch dir mounted (never the live config):
`docker run --rm --network none --entrypoint '/usr/lib/plexmediaserver/Plex SQLite' -v <scratch-db-dir>:/check lscr.io/linuxserver/plex:latest /check/<db-file> 'PRAGMA integrity_check;'`

#### What is excluded (`/etc/restic/excludes`)

Regenerable: `/var/lib/docker`, `/var/lib/containerd`, `/opt/containerd`,
`/var/lib/snapd`, `/snap`, `/var/cache`, `/var/tmp`, `/tmp`, `/var/crash`,
`/var/log/journal`, `/swap.img`, `~/.cache`, and Plex's `Cache`, `Codecs`,
`Crash Reports`, `Diagnostics`, `Drivers`, `Logs` and `Updates`. Also the
live Dolt data (above). Plex `Metadata` and `Media` (about 9GB) stay in:
Plex can refetch them, slowly, but custom artwork would be lost.

#### Plex database

`Plug-in Support/Databases/` under
`$NVME_DIR/plex/config/Library/Application Support/Plex Media Server/` holds
the live SQLite files and the dated copies that Plex's own scheduled task
writes every 3 days (`com.plexapp.plugins.library.db-YYYY-MM-DD`, same for
`library.blobs.db`). restic reads the live files while Plex runs, so they may
not be consistent; the dated copies are. To restore, stop Plex and copy the
newest dated pair over `com.plexapp.plugins.library.db` and
`com.plexapp.plugins.library.blobs.db`, after deleting their `-wal` and `-shm`
files.

---

## 7. Bring-up

```bash
git clone <repo> && cd docker-services
cp env.example .env     # fill in all variables (incl. CROWDSEC_BOUNCER_KEY and DOLT_BEADS_PASSWORD, see below)
# restore $NVME_DIR (default /usr/local/docker) from restic FIRST (see §5, §6)
touch acme/acme.json && chmod 600 acme/acme.json
docker compose up -d
./scripts/validate-traefik.sh
./scripts/validate-waf.sh
./scripts/validate-dolt.sh
```

`acme.json` must be `0600` or Traefik refuses to use it.

### Host addresses

None in `.env` or compose (`AGENTS.md` hard rule 4): Dolt publishes `:3307` on every host address. On orcrist the LAN
address is a DHCP lease on `enp2s0f0`; keep it reserved on the gateway, because `dolt.<domain>` (via
`orcrist.<domain>`) points at it. A changed address breaks that DNS record, not the stack.

### Dolt (Beads)

Background is in `dolt/README.md`. Do steps 1-3 before `docker compose up -d`.

1. In `.env`, set `DOLT_BEADS_PASSWORD` (`openssl rand -hex 32`, hex only). Compose refuses to render without it.
2. Stage the NAS config from the templates. Every subpath must exist, because compose mounts each one:
   ```bash
   mkdir -p /mnt/docker/dolt/servercfg /mnt/docker/dolt/init /mnt/docker/dolt/certs /mnt/docker/dolt/backups
   cp dolt/servercfg/config.yaml /mnt/docker/dolt/servercfg/
   cp dolt/init/01-beads-user.sh /mnt/docker/dolt/init/
   ```
   `servercfg/` must hold exactly one `*.yaml`. Keep both files identical to their templates: `deploy.sh` refuses to deploy and `validate-dolt.sh` fails while either differs, and both print the `cp` to run. `certs/` is filled by `dolt-certs.sh` when task-scheduler starts. Until then, dolt's guard refuses to start, and it restarts on its own once the certs exist.
3. Restore `$NVME_DIR/dolt/data` from `/mnt/docker/dolt/backups` (`dolt/RESTORE.md`). Skip this only for a deliberately empty server, where init creates the `beads` users on the first start.
4. Add the crontab line from §1.
5. For each new Beads project, run `./scripts/dolt-add-db.sh <prefix>`.
6. Run `./scripts/validate-dolt.sh`. Every check should pass; it has not yet been run on this host.

### CrowdSec (WAF)

1. Generate the bouncer key and put it in `.env`: `openssl rand -hex 32` -> `CROWDSEC_BOUNCER_KEY=`.
   **An empty key fails closed**: the plugin rejects it, `crowdsec@file` is never built, and every chained router breaks. `docker compose config` (so also `deploy.sh`, before `up`) refuses to render without it, and `validate-waf.sh` fails on it.
   Both containers read it as the compose secret `crowdsec_bouncer_key`; crowdsec registers it as bouncer `traefik` at start (`/run/secrets/bouncer_key_traefik`), so no `cscli bouncers add` is needed.
2. `$LOCALDOCKERDIR/crowdsec/{config,data}` are created on first start if missing (as `root`); pre-creating them as your user also works. Nothing to restore (see §5).
   Pre-create `$LOCALDOCKERDIR/traefik-logs` yourself with mode 700 (`install -d -m 700 $LOCALDOCKERDIR/traefik-logs`): docker would otherwise create it `root` 755, and the log holds API keys. Containers run as root, so CrowdSec and Traefik are unaffected. The rotation job re-enforces `chmod 700` on it every run.
   Rotation (`traefik-logrotate.sh`, 00:10) is copytruncate: copy to `access.log.<timestamp>`, truncate in place. Traefik opens the file `O_APPEND` and CrowdSec re-opens a truncated file, so nothing is missed; only the archive can lose a line written between the copy and the truncate. Keeps the current file + 2 rotated.
   On first start crowdsec installs the hub collections (needs internet) and registers with CAPI.
3. Nothing to create for Traefik's dynamic config: the chains (each starting with `crowdsec@file`), the `middlewares-*`, `crowdsec@file`
   and the Synology/Homebridge routers are all in `traefik-rules/`, mounted read-only at `/rules`. Not watched (it is the git checkout): `deploy.sh`
   restarts traefik when anything in `traefik-rules/` is newer than its last start; after a hand edit, `docker compose restart traefik`.
   Traefik no longer uses the NFS `/mnt/docker/traefik3` volume.
4. A Traefik restart costs ~2s of connection refused, with no 404s and no `does not exist` errors, because the middleware is in the file provider and exists as soon as Traefik loads. (As labels it did not exist until the traefik container turned `healthy`: the docker provider skips unhealthy containers, itself included, so the chains 404ed for ~2-4.5s.)
5. Run `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh`. Banned IPs pass for ~60s after a Traefik start (`streamStartupBlock=false`).

Bouncer key rotation: the key only registers when no `traefik` bouncer exists in `$LOCALDOCKERDIR/crowdsec/data`. To rotate:
Every chained router returns 403 from the delete until the recreate below (an outage), so run the steps back to back: `docker compose exec crowdsec cscli bouncers delete traefik` (this also deletes every auto-created `traefik@<ip>` entry; CrowdSec refuses to delete those on their own), update `CROWDSEC_BOUNCER_KEY` (must not be empty: an empty key fails closed and breaks every chained router), `docker compose up -d --force-recreate crowdsec traefik` (forces both to re-read the secret rather than relying on compose detecting the change),
run `./scripts/validate-waf.sh`. Unreadable request bodies (HTTP/2/3 POST/PUT/PATCH/DELETE without Content-Length) are blocked, not passed; GET/HEAD go to AppSec header-only and pass (`crowdsecAppsecUnreadableBodyBlock=true`, the plugin default). A key mismatch is not a silent fail-open: a wrong or unregistered key blocks every chained router with 403 (the LAPI stream fails open, but AppSec answers an unknown key with 401, and the plugin blocks on any AppSec error other than 500/502/503/504/unreachable). `validate-waf.sh` detects it (the normal-page check fails).

Docker access: none. CrowdSec does not read Authelia logs: the only way without a log file was Docker API access, which cannot be scoped below
"read every container's env/filesystem" with tecnativa socket-proxy. Authelia brute force is covered by its own `regulation:` (max_retries 3, find_time 120, ban_time 300,
in `/mnt/docker/authelia/configuration.yml`). Scenario `crowdsecurity/http-crawl-non_statics` is disabled (`DISABLE_SCENARIOS`): it would ban our own WAN IP.
CRS out-of-band is alerts only: its ban scenario `crowdsecurity/crowdsec-appsec-outofband` is also disabled there until tuned.

Chains cover every HTTP router except the file-provider `dsm-photo-rtr` and `http-catchall` (redirect to HTTPS only, no backend). The DSM TCP passthrough routers `grond-https-rtr`/`grond-admin-rtr` are TCP, so no HTTP middleware applies (see §8).
How the WAF works, why it fails open, and how to operate it: `docs/CROWDSEC.md`.

Expected validation result on the current host: **27 pass, 2 fail**.

- `kometa` — expected permanently. A 1 AM scheduled job with a Traefik route
  and nothing listening the rest of the day.
- `bazarr` — a current upstream bug, not a config problem. Its child process
  crash-loops on `TypeError: str expected, not bytes` at
  `app/database.py:404`, where `get_current_revision()` returns bytes into
  `os.environ`. Needs an upstream fix or a pin to a working image tag. On a
  fresh rebuild this may or may not reproduce depending on the image version.

### Traefik access log

It goes to a file, `$LOCALDOCKERDIR/traefik-logs/access.log` (full log, no status filter), not stdout, so it does not
appear in `docker logs traefik`. CrowdSec reads it.

- **Sensitive**: it records query strings, so API keys passed as `?apikey=` (*arr, hydra) are stored in clear text,
  `root:root` 0644, in `$LOCALDOCKERDIR/traefik-logs` (dir mode 700, owned by `jalance`; containers run as root; the
  rotation job re-enforces 700 every run).
- **Rotation**: task-scheduler, daily at 00:10 (`traefik-logrotate.sh`), copytruncate: `cp -p` to
  `access.log.<YYYYmmdd-HHMMSS>`, then truncate `access.log` in place. No signal, no Docker access, and `access.log`
  never disappears. Retention is the current file + 2 rotated (newest 2 by name).
- This is safe because Traefik opens the file `O_APPEND` (`openAccessLogFile`, v3.6), verified by truncating the live
  file: it restarted at 411 bytes, no NUL bytes. CrowdSec re-opens the truncated file (`Re-opening truncated file`) and
  keeps reading. A line written between the copy and the truncate is missing from the archive only; CrowdSec reads it
  as it is written.

---

## 8. Still missing for a no-direction rebuild

Known gaps are tracked as Beads issues (database `ds`, `bd show <id>`), not here:

| Issue | Gap |
|---|---|
| `ds-nhh` | rebuild as code: Ansible roles, SOPS secrets, private site repo, DR drill |
| `ds-hzh` | Synology-side configuration (shares, NFS exports, permissions) |
| `ds-1uw` | Remaining SQLite configs (Sonarr, Radarr, …) off NFS onto `$NVME_DIR` (§5), not `LOCALDOCKERDIR`; hydra is the reference |
| `ds-0lu` | DSM `home.<domain>` is TCP TLS passthrough, so the HTTP WAF cannot inspect it: host `cs-firewall-bouncer` + nftables (sudo) |
| `ds-o9h` | `dsm-photo-rtr` (`traefik-rules/synology.yml`) has no middlewares and no entryPoints: bypasses CrowdSec and Authelia |
| `ds-vhq` | CRS: after tuning, re-enable the `crowdsec-appsec-outofband` ban scenario, then consider `crs-inband` |
| `ds-zxh` | Authelia upgrade (running 4.21.0), then a local `log_file_path` + CrowdSec file acquisition (needs rotation) |
| `ds-a6m` | Delete `/mnt/docker/traefik3` (old pre-WAF rules copy, stale January `acme.json`) and the `traefik_acme_config` volume |
| `ds-2xi` | `chain-basic-auth`/`middlewares-basic-auth` are unused and point at an unmounted `/shared/.htpasswd` |
| `ds-5gn` | Vestigial Cloudflare `trustedIPs` on the https entrypoint (DNS is not proxied, so `X-Forwarded-For` can be spoofed) |
| `ds-5fh` | WAN-source ban test (only LAN/hairpinned sources tested; the whitelist was never exercised) |
| `ds-qix` | Human browser checks of the WAF: Calibre upload, Sonarr/Radarr UI actions, SABnzbd NZB upload |
