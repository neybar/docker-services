# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Home server Docker infrastructure orchestrating self-hosted services via Docker Compose behind a Traefik reverse proxy with Authelia SSO/2FA.

## Architecture

### Networks
- **t2_proxy** (192.168.90.0/24): Main network for Traefik and all web-accessible services
- **socket_proxy** (192.168.91.0/24): Isolated network for Docker Socket Proxy only

Both networks are external — create before first run:
```bash
docker network create --gateway 192.168.90.1 --subnet 192.168.90.0/24 t2_proxy
docker network create --gateway 192.168.91.1 --subnet 192.168.91.0/24 socket_proxy
```

### Security Stack
1. **Traefik** — Reverse proxy, Let's Encrypt certs via Cloudflare DNS challenge
2. **Docker Socket Proxy** — Restricts Docker API access (never expose the socket directly). CrowdSec has **no** Docker API access
3. **CrowdSec** — Traefik bouncer plugin (bans) + AppSec WAF, first entry of every middleware chain, so banned IPs and attack payloads are stopped before Authelia. Not every router: file-provider router `dsm-photo-rtr` bypasses it (see CrowdSec notes)
4. **Authelia** — SSO/2FA on all external-facing services via `chain-authelia@file` middleware

### Storage
- **NFS volumes** (Synology at 192.168.0.6): Service configs and media libraries
- **Local NVME** (`/usr/local/plex`, `/tmp/plex_transcode`): Plex config and transcode scratch.
  `/usr/local/plex` holds the 13GB Plex library database and is **in no backup** — a rebuild
  silently starts Plex with an empty library. See `REBUILD.md` §5-6.
- **Local disk** (`$LOCALDOCKERDIR/crowdsec/{config,data}`, `$LOCALDOCKERDIR/traefik-logs`): CrowdSec config + SQLite DB
  and Traefik's access log. Gitignored. Regenerable — losing it loses only decisions/alerts history.
- **Local NVME** (`/usr/local/nzbhydra2/database`): NZBHydra2's H2 database — mounted at `/config/database`,
  nested inside the NFS `/config`. Embedded random-access databases must not live on NFS (see Notes).

### Services

| Category | Services |
|----------|----------|
| Infrastructure | Traefik, Socket Proxy, CrowdSec, Authelia, Portainer, Task Scheduler |
| Media | Plex (GPU), Sonarr, Radarr, Bazarr, SABnzbd, NZBHydra2 |
| Collection Mgmt | Kometa (runs daily at 1 AM) |
| Books | Calibre-Web, Lazy Librarian |
| DNS | Pi-hole (host port 53) |
| Home Automation | Home Assistant (privileged, host network) |
| Dashboard | Organizr |
| Utilities | iSponsorBlockTV, LibreSpeed, Smokeping, Slideshow Updater |

## Key Files

- `docker-compose.yml` — All service definitions
- `env.example` — Required environment variables (copy to `.env`)
- `kometa/config.yml.example` — Kometa collection manager config template
- `scripts/validate-traefik.sh` — Post-change validation script
- `REBUILD.md` — **Bringing this stack up on a fresh host.** Host prerequisites, the Synology
  mounts and `resolved.conf` changes that are *not* in this repo, which local paths hold
  irreplaceable state, and what is still missing for an unattended rebuild.
- `crowdsec-config/acquis.d/` — CrowdSec log/AppSec acquisition (`traefik.yaml`, `appsec.yaml`), mounted read-only
- `plugins-local/` — vendored Traefik CrowdSec bouncer plugin (pinned tag + bump procedure in its `README.md`)
- `scripts/validate-waf.sh` — CrowdSec/AppSec validation script
- `acme/acme.json` — Let's Encrypt certs (Traefik-managed, chmod 600)

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `DOMAINNAME` | Primary domain for all subdomains |
| `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ZONEID` | DNS challenge |
| `DOCKERDIR` | NFS mount path (e.g. `/mnt/docker`) |
| `LOCALDOCKERDIR` | Local storage path (`/home/jalance/Projects/docker-services`, on the 1TB TeamGroup SATA SSD that replaced the failed 870 EVO on 2026-10-17). See `REBUILD.md` §5 |
| `SYNOLOGYDIR` | Synology NAS mount |
| `CROWDSEC_BOUNCER_KEY` | Traefik-to-CrowdSec bouncer key (`openssl rand -hex 32`); passed to both CrowdSec (registers it as bouncer `traefik`) and Traefik as the compose secret `crowdsec_bouncer_key` |
| `HOST_IP` | Host IP for DSM access through Traefik |
| `PLEX_TOKEN` | Plex auth token (used by Kometa) |
| `TMDB_API_READ_ACCESS_TOKEN` | TMDb v4 read token (used by Kometa) |

## Adding New Services

1. Add service to `docker-compose.yml` using an existing service (e.g. radarr) as a template
2. Connect to `t2_proxy` network
3. Add Traefik labels: `traefik.http.routers.<name>.rule=Host(\`<name>.$DOMAINNAME\`)`
4. Use `chain-authelia@file` middleware. `chain-authelia`, `chain-no-auth` and `chain-basic-auth` all start with `crowdsec@docker`, so a new service gets the WAF automatically. Never attach a router without one of these chains — it would bypass CrowdSec.
5. Add NFS volume if config persistence needed (follow existing pattern, Synology at 192.168.0.6)
6. Add subdomain to `SERVICES` array in `scripts/validate-traefik.sh`
7. Run `./scripts/validate-traefik.sh`

## Validation

**Always run after modifying `docker-compose.yml`:**

```bash
./scripts/validate-traefik.sh
```

Checks HTTPS access, HTTP→HTTPS redirect, security headers, TLS cert, and Traefik API for all services.

Also run `./scripts/validate-waf.sh` after changes touching Traefik, CrowdSec or the chains (containers up, bouncer pulling, `/.env` probe blocked, normal page allowed).

## Logging

All containers use `*default-logging` (json-file, 10MB max, 3 files). Application-level logs on NFS have built-in rotation — do not add external logrotate.

Traefik's access log is the exception: it goes to a file (`$LOCALDOCKERDIR/traefik-logs/access.log`, full log, no status filter), not stdout, so it no longer
appears in `docker logs traefik`. task-scheduler rotates it daily at 00:10 (`traefik-logrotate.sh`: rename to `access.log.<YYYYmmdd-HHMMSS>`, then `docker kill -s USR1 traefik`; on signal failure the file is moved back); retention is the current file + 2 rotated (newest 2 by name). Lines written between the rename and Traefik's USR1 reopen land in the rotated file and are not parsed (accepted gap).
The full log is **sensitive**: it records query strings, so API keys passed as `?apikey=` (*arr, hydra) are stored in clear text, `root:root` 0644, in `$LOCALDOCKERDIR/traefik-logs` (dir mode 700, owned by `jalance`; containers run as root).

## Git Workflow

**Never commit directly to master.** Always use a feature branch, push, and open a PR.

## Notes

- **Plex**: LinuxServer.io image with `/dev/dri` GPU transcoding; `VERSION=public` enables auto-updates on container restart
- **Task Scheduler**: Docker cleanup nightly at midnight; Plex restart Sundays at 3 AM
- **Kometa**: Runs daily at 1 AM; reads `PLEX_TOKEN` and `TMDB_API_READ_ACCESS_TOKEN` from env; config at `/mnt/docker/kometa/config.yml`
- **NZBHydra2 (hydra)**: H2 database lives on local NVME at `/usr/local/nzbhydra2/database`, *not* NFS.
  The Synology periodically revokes NFSv4 lock state (`NFS: : lost 3 locks` in `dmesg`, ~every 9 days);
  the kernel surfaces that as EIO (`recover_lost_locks` is off by default), and H2 treats any I/O error as
  fatal with no reopen path, so one blip wedges the DB until the container restarts
  ([h2database#1954](https://github.com/h2database/h2database/issues/1954), open since 2019). SQLite-based
  services tolerate this; H2 does not. `stop_grace_period: 120s` is required so H2 can compact on shutdown.
  The path is not independently configurable — H2's URL is `${nzbhydra.dataFolder}/database/nzbhydra` — hence
  the nested mount.
- **Pi-hole**: Host port 53. No systemd-resolved conflict — `DNSStubListener=no` is already set in
  `/etc/systemd/resolved.conf`. **Cold standby only** — NextDNS serves live DNS (host resolvers are
  `45.90.28.234`/`45.90.30.234`) and nothing points at Pi-hole; it is kept in case NextDNS is dropped.
  Runs v6, which reads **only** `FTLCONF_<section>_<setting>` env vars — all v5-style vars
  (`WEBPASSWORD`, `DNS1`, `ServerIP`, `PUID`/`PGID`, `CONDITIONAL_FORWARDING*`, …) are silently ignored.
  `PUID`/`PGID` in particular are a LinuxServer.io convention the official image does not implement: it
  starts as root and FTL drops to its own `pihole` user (uid 1000). The live config lives in
  `pihole.toml`, which is **gitignored** (it lives under `$LOCALDOCKERDIR`), so the settings that matter are
  restated as `FTLCONF_*` in compose to keep them reproducible. Settings supplied via env become
  read-only in the web UI. FTL's long-term query database is off (`FTLCONF_database_maxDBdays: "0"`) —
  it had reached 1.46GB on the old (since failed) /home SSD and corrupted itself with unreadable pages.
  `gravity.db` (the blocklist, ~86k domains, refreshed by in-container cron Sundays 04:26) is what makes the standby
  usable — keep that one. v6 logs to the `/var/log/pihole/` **directory** and those logs are not
  persisted; the old single-file `pihole.log` bind mount was a v5 path and did nothing.
- **CrowdSec** (WAF): Traefik plugin `crowdsec@docker` (labels on the `traefik` service) does stream-mode bans (LAPI `crowdsec:8080`, refresh 60s) and AppSec (`crowdsec:7422`)
  on each request. Config + DB on local disk (see Storage); `acquis.d/` is tracked and mounted read-only.
  - **Fails open on purpose** (Authelia is still the auth layer): `updateMaxFailure=-1` (the default `0` would block *all* traffic once the LAPI is unreachable in stream mode),
    `streamStartupBlock=false` (Traefik does not wait for CrowdSec at start, so banned IPs pass for ~60s until the first sync), and AppSec unreachable / failure / unreadable-body all pass.
    Verified: crowdsec stopped 100s, services kept answering, `/.env` was not blocked.
  - **Whitelisting**: parser `crowdsecurity/whitelists` (127/8, 10/8, 172.16/12, 192.168/16, ::1) suppresses *bans* for LAN and docker nets. It does **not** exempt AppSec *blocking*:
    a LAN `/.env` probe gets 403 and an alert, no ban. Tests from this host therefore see 403s.
  - **Rules**: `appsec-default` (virtual patching + generic rules) blocks inline. OWASP CRS (`crowdsecurity/crs`) runs **out-of-band only**: alerts only, no inline blocks and no bans. Its ban scenario `crowdsecurity/crowdsec-appsec-outofband` is disabled (`DISABLE_SCENARIOS`) until tuned.
    Re-enabling it, and later `crs-inband`, is a `REBUILD.md` §8 follow-up. Do not add either casually.
  - **Authelia logs are NOT read by CrowdSec.** The only way without a log file was Docker API access, and the tecnativa socket-proxy cannot scope that below
    "read every container's env and filesystem" (`CONTAINERS=1` exposes `/containers/*/json` and `/archive`, i.e. TLS keys and other containers' env). Brute force on Authelia is covered by
    Authelia's own `regulation:` (max_retries 3, find_time 120, ban_time 300, in `/mnt/docker/authelia/configuration.yml`). Follow-up in `REBUILD.md` §8.
  - **Disabled scenarios** (`DISABLE_SCENARIOS` in compose, space-separated): `crowdsecurity/crowdsec-appsec-outofband` (see Rules), and `crowdsecurity/http-crawl-non_statics`: with the full access log, one *arr/Organizr page load makes many non-static requests,
    so it would ban our own WAN IP for 4h. Other `base-http-scenarios` stay on.
  - **CAPI**: default registration is on. This pulls the community blocklist and shares your attacker IPs with CrowdSec. The console is not enrolled (optional manual `cscli console enroll`).
  - **Versions**: image pinned to `v1.8.1`; the bouncer plugin is pinned and vendored (bump: `plugins-local/README.md`). Hub collections are **not** version-pinned and update with the image/hub.
  - **Operate**: `docker compose exec crowdsec cscli decisions list` / `alerts list` / `metrics show appsec`. Unban: `docker compose exec crowdsec cscli decisions delete --ip <ip>`
    (takes effect within ~60s, the stream refresh).
  - **Docker access**: none. CrowdSec is on `t2_proxy` only, not on `socket_proxy`, and has no socket mount.
  - **Ping**: `/ping` is on an unpublished `ping` entrypoint (`:8082`), not on the published `:8080` one; `http`, `https` and `dsm-admin` are set `asDefault=true` so `ping` does not become a default entrypoint for routers without explicit entryPoints. The healthcheck must repeat `--ping.entryPoint=ping --entryPoints.ping.address=:8082`
    because `traefik healthcheck` does not read the daemon's flags.
  - **Bouncer key rotation**: key mismatch silently disables the WAF (fail-open); an *empty* key fails closed (`deploy.sh` and `validate-waf.sh` check for it). Procedure: `REBUILD.md` §7.
  - **Rollback order is mandatory** (remove `crowdsec@docker` from the NFS chains *before* reverting, or every chained router breaks), as is the merge procedure: `REBUILD.md` §7.
  - **Bypass**: file-provider router `dsm-photo-rtr` (`rules/synology.yml`, `home.thelances.net/photo` to Synology :80) has no middlewares and no entryPoints, so it skips CrowdSec and Authelia on all default entrypoints (`http`, `https`, `dsm-admin`).
    Pre-existing, not changed (`REBUILD.md` §8).
  - **Traefik file rules**: Traefik does **not** reload edits to `/mnt/docker/traefik3/rules/` (NFS, no inotify). Run `docker compose restart traefik` after editing.
    Each Traefik start logs a ~1s burst of `middleware "crowdsec@docker" does not exist` errors (file provider loads before the docker provider); harmless.
  - **Follow-ups / out of scope** (DSM TCP passthrough, CRS in-band, Authelia log acquisition, rules into repo, Cloudflare `trustedIPs`): see `REBUILD.md` §8.
- **Home Assistant**: Privileged mode with host network (required for device access)
