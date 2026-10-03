# Rebuilding This Homelab

Everything needed to bring this stack up on a fresh host. The goal is that a
rebuild needs **no verbal instructions** — if you find yourself guessing, that
is a bug in this document, so fix it here.

Read alongside `CLAUDE.md` (architecture) and `env.example` (variables).

---

## 1. What is NOT in this repo

Start here, because these are the things a fresh host will not have and
`docker compose up` will not create. This is the current honest gap list.

| Thing | Where it lives | Status |
|---|---|---|
| 10 CIFS mounts (`/mnt/*`) | `/etc/fstab` | **not captured** — template below |
| CIFS credentials | `/etc/cifspwd` (root, `0600`) | **secret, never commit** |
| `DNSStubListener=no` | `/etc/systemd/resolved.conf` | **not captured** — needed for Pi-hole |
| Plex library database | `/usr/local/plex` (13GB) | **not backed up anywhere** — see §6 |
| Minecraft manager | separate repo at `~/games` | own git repo, no remote |

---

## 2. Host prerequisites

Verified against the current host:

- Ubuntu 24.04 LTS
- Docker 29.x with Compose v5 (`docker compose`, not `docker-compose`)
- Packages: `cifs-utils` (required for the mounts), `git`
- Useful for diagnostics, not required to run the stack: `smartmontools`,
  `sqlite3` — both were missing on this host when they were first needed
- A user whose `uid:gid` matches `PUID`/`PGID` in `.env` (currently `1026:100`)

### Pi-hole needs port 53 free

Pi-hole binds host port 53, which collides with systemd-resolved's stub
listener. Required:

```
# /etc/systemd/resolved.conf
DNSStubListener=no
```

Then `sudo systemctl restart systemd-resolved`. Without this, the `pihole`
container fails to bind and the stack comes up degraded.

---

## 3. Synology mounts

The NAS is `192.168.0.6`. Ten CIFS shares are mounted on the host; service
configs and all media live on them. Create `/etc/cifspwd` first:

```
# /etc/cifspwd  — chmod 600, owned by root
username=<user>
password=<password>
```

Then one `/etc/fstab` line per share, all using the same options:

```
//192.168.0.6/<share> /mnt/<share> cifs user,vers=3.0,uid=jalance,gid=users,rw,suid,nobrl,file_mode=0600,dir_mode=0700,credentials=/etc/cifspwd 0 0
```

Shares: `audiobooks` `backups` `docker` `downloads` `ebooks` `music` `photo`
`software` `video` `web`

`nobrl` matters — it disables byte-range locking, which is what lets SQLite
work at all over CIFS. Do not drop it.

Note the containers reach the same Synology paths over **NFS** via Docker
volume `driver_opts`, independently of these host CIFS mounts. Both protocols
touch the same files; see §5 for why that matters.

---

## 4. Docker networks

Both are external and must exist before first run:

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

| Path | Holds | If empty on rebuild |
|---|---|---|
| `/usr/local/plex` | Plex library DB (13GB) | **watch history, collections, ratings and metadata all gone** |
| `/usr/local/nzbhydra2/database` | NZBHydra2 H2 database (98MB) | search history and stats lost; config is safe in `nzbhydra.yml` on NFS |
| `/tmp/plex_transcode` | transcode scratch | nothing — intentionally ephemeral |

Restore `/usr/local/plex` from backup **before** first `up -d`, or Plex will
initialise an empty library.

### Why these are local and not on the NAS

Embedded databases that do random-access reads do not survive network
filesystems here. The Synology periodically revokes NFSv4 lock state — the
kernel logs `NFS: : lost 3 locks`, roughly every 9 days — and with
`recover_lost_locks` off by default (the kernel calls recovery a
data-corruption risk) that surfaces to the application as `EIO`. `hard`,
`timeo` and `retrans` do not help; they only cover timeouts.

H2 treats any I/O error as fatal, never reopens its file handle, and stays
broken until the process restarts
([h2database#1954](https://github.com/h2database/h2database/issues/1954), open
since 2019). SQLite-based services survive because they reopen and retry.

### Do not point local storage at /home

`/dev/sda` (the Samsung 870 EVO holding `/home`) is failing: 957 reallocated
sectors, ~85% of the spare pool consumed, and 65,535+ SATA PhyRdy→PhyNRdy
transitions. `/` and `/var/lib/docker` are on the healthy NVMe.

`LOCALDOCKERDIR` currently resolves to `/home/jalance/Projects/docker-services`
— on that failing disk. **`TODO-local-configs.md` proposes moving ~85GB of
service configs to `$LOCALDOCKERDIR`; do not run that plan until the variable
points at the NVMe.**

---

## 6. Backups — what is covered and what is not

| Data | Location | Backed up? |
|---|---|---|
| Service configs | `/mnt/docker/<service>/` (NAS) | yes, Synology handles it |
| Media libraries | NAS shares | yes |
| This repo | GitHub | yes |
| Minecraft worlds | `/mnt/backups/minecraft-rescue-*` | manual snapshot, 2026-10-03 |
| **Plex library DB** | `/usr/local/plex` | **NO — see below** |
| NZBHydra2 H2 DB | `/usr/local/nzbhydra2/database` | no, and acceptable (history only) |

### Plex database backup (required, not yet implemented)

`/usr/local/plex` is 13GB but only the `Databases/` directory is
irreplaceable — the rest is cache and transcodes that regenerate. A periodic
tar of just that directory to `/mnt/backups` covers the real risk:

```
/usr/local/plex/Library/Application Support/Plex Media Server/Plug-in Support/Databases/
```

Plex should be stopped, or its scheduled-task backup used, so the SQLite files
are captured consistently. The `task-scheduler` service already runs cron jobs
for this stack and is the natural home for it.

---

## 7. Bring-up

```bash
git clone <repo> && cd docker-services
cp env.example .env     # fill in all 21 variables
# restore /usr/local/plex from backup FIRST (see §5)
touch acme/acme.json && chmod 600 acme/acme.json
docker compose up -d
./scripts/validate-traefik.sh
```

`acme.json` must be `0600` or Traefik refuses to use it.

Expected validation result on the current host: **27 pass, 2 fail**.

- `kometa` — expected permanently. A 1 AM scheduled job with a Traefik route
  and nothing listening the rest of the day.
- `bazarr` — a current upstream bug, not a config problem. Its child process
  crash-loops on `TypeError: str expected, not bytes` at
  `app/database.py:404`, where `get_current_revision()` returns bytes into
  `os.environ`. Needs an upstream fix or a pin to a working image tag. On a
  fresh rebuild this may or may not reproduce depending on the image version.

---

## 8. Still missing for a no-direction rebuild

Known gaps, for later work:

- [ ] fstab and `resolved.conf` as checked-in templates or a bootstrap script
- [ ] A `scripts/bootstrap-host.sh` doing packages → networks → mounts → checks
- [ ] Plex database backup job (§6) wired into `task-scheduler`
- [ ] Secret handling for `.env` and `/etc/cifspwd` documented end to end
- [ ] Synology-side configuration (shares, NFS exports, permissions) captured
- [ ] `TODO-local-configs.md` reconciled: hydra already moved off NFS; the
      remaining services still need it, and `LOCALDOCKERDIR` must be repointed
      to the NVMe first
- [ ] `.claude/plans/typed-wondering-hennessy.md`, referenced by
      `TODO-local-configs.md`, does not exist — either restore or drop the link
