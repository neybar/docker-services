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
| `/mnt/docker/traefik3/rules/middleware-chains.yml` | NFS (Synology) | **not in git** — contents in §7; without it every chained router breaks (`dsm-photo-rtr`, `http-catchall` and the DSM TCP routers do not use the chains) |
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

| Path | Holds | If empty on rebuild |
|---|---|---|
| `/usr/local/plex` | Plex library DB (13GB) | **watch history, collections, ratings and metadata all gone** |
| `/usr/local/nzbhydra2/database` | NZBHydra2 H2 database (98MB) | search history and stats lost; config is safe in `nzbhydra.yml` on NFS |
| `/tmp/plex_transcode` | transcode scratch | nothing — intentionally ephemeral |
| `$LOCALDOCKERDIR/crowdsec/{config,data}` | CrowdSec config + SQLite DB | nothing irreplaceable — regenerated on first start; ban decisions and alert history are lost (CAPI blocklist re-syncs) |
| `$LOCALDOCKERDIR/traefik-logs` | Traefik access log (`access.log`, current file + 2 rotated `access.log.<timestamp>`; dir mode 700) | nothing — log history only |

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

### /home disk

`/home` was on a Samsung 870 EVO that failed (957 reallocated sectors, 15k+
uncorrectable errors, eventually refusing writes). On 2026-10-17 it was
replaced by a 1TB TeamGroup T-Force Vulcan Z SATA SSD (ext4, label `home`,
UUID `24be54cb-fcbc-4868-907d-c290dd2729a8`) and `/home` was copied over.
`/` and `/var/lib/docker` are on the NVMe.

`LOCALDOCKERDIR` resolves to `/home/jalance/Projects/docker-services`, on the
new SSD. The failing-disk hold on `TODO-local-configs.md` no longer applies.

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
cp env.example .env     # fill in all 22 variables (incl. CROWDSEC_BOUNCER_KEY, see below)
# restore /usr/local/plex from backup FIRST (see §5)
touch acme/acme.json && chmod 600 acme/acme.json
# create /mnt/docker/traefik3/rules/middleware-chains.yml (see CrowdSec below)
docker compose up -d
./scripts/validate-traefik.sh
./scripts/validate-waf.sh
```

`acme.json` must be `0600` or Traefik refuses to use it.

### CrowdSec (WAF)

1. Generate the bouncer key and put it in `.env`: `openssl rand -hex 32` -> `CROWDSEC_BOUNCER_KEY=`.
   **An empty key fails closed**: the plugin rejects it, `crowdsec@file` is never built, and every chained router breaks. `docker compose config` (so also `deploy.sh`, before `up`) refuses to render without it, and `validate-waf.sh` fails on it.
   Both containers read it as the compose secret `crowdsec_bouncer_key`; crowdsec registers it as bouncer `traefik` at start (`/run/secrets/bouncer_key_traefik`), so no `cscli bouncers add` is needed.
2. `$LOCALDOCKERDIR/crowdsec/{config,data}` are created on first start if missing (as `root`); pre-creating them as your user also works. Nothing to restore (see §5).
   Pre-create `$LOCALDOCKERDIR/traefik-logs` yourself with mode 700 (`install -d -m 700 $LOCALDOCKERDIR/traefik-logs`): docker would otherwise create it `root` 755, and the log holds API keys. Containers run as root, so CrowdSec and Traefik are unaffected. The rotation job re-enforces `chmod 700` on it every run.
   Rotation (`traefik-logrotate.sh`, 00:10) is copytruncate: copy to `access.log.<timestamp>`, truncate in place. Traefik opens the file `O_APPEND` and CrowdSec re-opens a truncated file, so nothing is missed; only the archive can lose a line written between the copy and the truncate. Keeps the current file + 2 rotated.
   On first start crowdsec installs the hub collections (needs internet) and registers with CAPI.
3. Create `/mnt/docker/traefik3/rules/middleware-chains.yml` with exactly this content. It is **not in git**; `crowdsec@file` is defined by the tracked `traefik-rules/crowdsec.yml`, whose directory `traefik-rules/` compose bind-mounts read-only at `/config/rules/repo/` (a subdirectory of the file provider dir, nested inside the NFS `traefik_config` volume, so an empty `repo/` directory appears in `/mnt/docker/traefik3/rules/`; harmless):

   ```yaml
   http:
     middlewares:
       chain-no-auth:
         chain:
           middlewares:
             - "crowdsec@file"
             - "middlewares-rate-limit"
             - "middlewares-secure-headers"

       chain-basic-auth:
         chain:
           middlewares:
             - "crowdsec@file"
             - "middlewares-rate-limit"
             - "middlewares-secure-headers"
             - "middlewares-basic-auth"

       chain-authelia:
         chain:
           middlewares:
             - "crowdsec@file"
             - "middlewares-rate-limit"
             - "middlewares-secure-headers"
             - "middlewares-authelia"
   ```

   The `middlewares-*` definitions live in `middlewares.yml` in the same `rules/` directory (also not in git; not reproduced here).
4. `docker compose restart traefik` after creating or editing the file — Traefik does not see edits on NFS (no inotify), and the file provider never watches subdirectories, so this also applies to `traefik-rules/crowdsec.yml`. `deploy.sh` runs `up -d`, which recreates traefik only when its compose config changes, so a merge that changes only `traefik-rules/` does **not** reach the running Traefik: restart it by hand. Measured per restart: ~2s connection refused, no 404s and no `does not exist` errors, because the middleware is in the file provider and exists as soon as Traefik loads. (As labels it did not exist until the traefik container turned `healthy`: the docker provider skips unhealthy containers, itself included, so the chains 404ed for ~2-4.5s.)
5. Run `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh`. Banned IPs pass for ~60s after a Traefik start (`streamStartupBlock=false`).

Rollback if the WAF misbehaves. **Order is mandatory**: first remove the `crowdsec@file` lines from the three chains and `docker compose restart traefik`,
*then* revert the PR. Reverting first auto-deploys and removes the mount (so `crowdsec@file`) while the NFS chains still reference it, so every chained router breaks.

Bouncer key rotation: the key only registers when no `traefik` bouncer exists in `$LOCALDOCKERDIR/crowdsec/data`. To rotate:
Every chained router returns 403 from the delete until the recreate below (an outage), so run the steps back to back: `docker compose exec crowdsec cscli bouncers delete traefik` (this also deletes every auto-created `traefik@<ip>` entry; CrowdSec refuses to delete those on their own), update `CROWDSEC_BOUNCER_KEY` (must not be empty: an empty key fails closed and breaks every chained router), `docker compose up -d --force-recreate crowdsec traefik` (forces both to re-read the secret rather than relying on compose detecting the change),
run `./scripts/validate-waf.sh`. Unreadable request bodies (HTTP/2/3 without Content-Length) are blocked, not passed (`crowdsecAppsecUnreadableBodyBlock=true`, the plugin default). A key mismatch is not a silent fail-open: a wrong or unregistered key blocks every chained router with 403 (the LAPI stream fails open, but AppSec answers an unknown key with 401, and the plugin blocks on any AppSec error other than 5xx/unreachable). `validate-waf.sh` detects it (the normal-page check fails).

Docker access: none. CrowdSec does not read Authelia logs: the only way without a log file was Docker API access, which cannot be scoped below
"read every container's env/filesystem" with tecnativa socket-proxy. Authelia brute force is covered by its own `regulation:` (max_retries 3, find_time 120, ban_time 300,
in `/mnt/docker/authelia/configuration.yml`). Scenario `crowdsecurity/http-crawl-non_statics` is disabled (`DISABLE_SCENARIOS`): it would ban our own WAN IP.
CRS out-of-band is alerts only: its ban scenario `crowdsecurity/crowdsec-appsec-outofband` is also disabled there until tuned.

**Merging the CrowdSec PR.** The live stack already runs the branch and the NFS chains already reference `crowdsec@file`, so do **not** run `docker compose up` from `master`
before the PR is merged (it would remove the mount and the middleware). Procedure: merge the PR, `git switch master` in the deploy checkout, `./scripts/deploy.sh` (or re-run the failed Deploy workflow).
The merge-triggered deploy refuses while the checkout is on the feature branch; that is expected. See `docs/DEPLOY.md`.
Chains cover every HTTP router except the file-provider `dsm-photo-rtr` and `http-catchall` (redirect to HTTPS only, no backend). The DSM TCP passthrough routers `grond-https-rtr`/`grond-admin-rtr` are TCP, so no HTTP middleware applies (see §8).
The Traefik access log holds API keys from query strings (`$LOCALDOCKERDIR/traefik-logs`, `root:root` 0644).

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
- [ ] DSM `home.thelances.net` is TCP TLS passthrough, so the HTTP WAF cannot inspect it. Covering it needs the host
      `cs-firewall-bouncer` + nftables (needs sudo)
- [ ] File-provider router `dsm-photo-rtr` (`rules/synology.yml`, `home.thelances.net/photo` to Synology :80) has no middlewares and no entryPoints,
      so it bypasses CrowdSec and Authelia on all default entrypoints (`http`, `https`, `dsm-admin`). Pre-existing; not changed
- [ ] CrowdSec CRS after a tuning period: re-enable the `crowdsecurity/crowdsec-appsec-outofband` ban scenario (remove it from `DISABLE_SCENARIOS`), then consider in-band blocking (`crs-inband`); today CRS is out-of-band, alerts only
- [ ] Authelia upgrade (running 4.21.0). Afterwards set `log_file_path` to a local-disk file and add a CrowdSec file acquisition for it
      (needs a rotation design, like `traefik-logrotate.sh`); until then Authelia is protected by its own `regulation:` only
- [ ] Move the rest of `/mnt/docker/traefik3/rules` into the repo (`crowdsec.yml` is tracked in `traefik-rules/`; the chains and `middlewares-*` are only documented in §7)
- [ ] Vestigial Cloudflare `trustedIPs` on the https entrypoint: DNS is not Cloudflare-proxied (resolves directly to the WAN IP), so any
      Cloudflare-origin request can spoof `X-Forwarded-For`. Flagged, not changed
- [ ] WAN-source ban test: only LAN/hairpinned sources could be tested, and the parser whitelist was not exercised by a non-whitelisted source
- [ ] Human browser checks of the WAF: Plex playback, HA UI, Calibre upload, Organizr iframes, Sonarr/Radarr UI actions, SABnzbd NZB upload
- [ ] `.claude/plans/typed-wondering-hennessy.md`, referenced by
      `TODO-local-configs.md`, does not exist — either restore or drop the link
