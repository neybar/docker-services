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
- **Local NVMe (`$NVME_DIR`)**: every service that needs orcrist's NVMe, at `$NVME_DIR/<service>/<role>`.
  `NVME_DIR` defaults to `/usr/local/docker` in compose (`${NVME_DIR:-/usr/local/docker}`, optional in `.env`); it is on
  `/`, the NVMe. It is **not** `LOCALDOCKERDIR` (the repo checkout, on the /home SATA SSD). The list is the table in
  `scripts/lib/nvme-paths.sh`, which `scripts/ci/test-nvme-paths.sh` checks against compose:
  - **Plex** `plex/config` (`/config`): the 13GB library database, **in no backup** — a rebuild silently starts Plex
    with an empty library (`REBUILD.md` §5-6). `plex/transcode` (`/transcode`): scratch, for transcode speed.
  - **NZBHydra2** `nzbhydra2/database` (`/config/database`, nested inside the NFS `/config`): the H2 database.
    Embedded random-access databases must not live on NFS (see Notes).
  - **Dolt** `dolt/data` (`/var/lib/dolt`, the image's own path): every Beads database. Losing it loses them until
    restored from `/mnt/docker/dolt/backups`.

  The paths moved from `/usr/local/plex`, `/tmp/plex_transcode`, `/usr/local/nzbhydra2/database` and
  `/usr/local/dolt/data`. `scripts/migrate-nvme-layout.sh` moves them (dry run by default; `sudo … --apply`) and leaves
  a symlink at each legacy path. `deploy.sh` refuses to deploy while a legacy path still holds real data and its
  `$NVME_DIR` path is missing or empty (`nvme_layout_check`), because compose would create it empty.
- **Local disk** (`$LOCALDOCKERDIR/crowdsec/{config,data}`, `$LOCALDOCKERDIR/traefik-logs`): CrowdSec config + SQLite DB
  and Traefik's access log. Gitignored. Regenerable — losing it loses only decisions/alerts history.
- **NFS** `dolt_config` (`:/volume1/docker/dolt`, CIFS on the host at `/mnt/docker/dolt`): Dolt's `servercfg/`, `init/`, `certs/` and `backups/`, each mounted by subpath. `dolt/` in the repo holds only templates (see the Dolt note).

### Services

| Category | Services |
|----------|----------|
| Infrastructure | Traefik, Socket Proxy, CrowdSec, Authelia, Portainer, Task Scheduler, Dolt (Beads; `:3307` on LAN and Tailscale, no Traefik) |
| Media | Plex (GPU), Sonarr, Radarr, Bazarr, SABnzbd, NZBHydra2 |
| Collection Mgmt | Kometa (runs daily at 1 AM) |
| Books | Calibre-Web, Lazy Librarian |
| DNS | Pi-hole (host port 53 on `$HOST_IP` only) |
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
- `traefik-rules/` — **all** Traefik file-provider config: `middleware-chains.yml`, `middlewares.yml`, `crowdsec.yml` (the `crowdsec@file` middleware), and the routers for services outside compose (`homebridge.yml`, `synology.yml`). Bind-mounted read-only at `/rules` (the file provider directory). **Not watched**: `deploy.sh` restarts traefik when anything in `traefik-rules/` is newer than its last start; by hand, `./scripts/compose.sh restart traefik`. The domain is written as `{{ env "DOMAINNAME" }}` (Go template; `DOMAINNAME` is passed to the traefik container)
- `plugins-local/` — vendored Traefik CrowdSec bouncer plugin (pinned tag + bump procedure in its `README.md`)
- `scripts/validate-waf.sh` — CrowdSec/AppSec validation script
- `.github/workflows/integration.yml` + `scripts/ci/` — runs the validate scripts for trusted PRs on the orcrist runner against the live stack (read-only); trigger rules in `docs/DEPLOY.md`
- `scripts/lib/validate-common.sh` — helpers shared by the validate scripts (colors, `.env` loading, counters, `print_result`); `.shellcheckrc` lets ShellCheck follow the `source`
- `scripts/compose.sh` — `docker compose` wrapper for use by hand; derives `HOST_IP`/`TAILSCALE_IP` via `scripts/lib/host-addrs.sh` (see Environment Variables)
- `scripts/lib/dolt-nas.sh` — read-only comparison of Dolt's live NAS config with the `dolt/` templates (used by `deploy.sh` and `validate-dolt.sh`)
- `scripts/lib/nvme-paths.sh` — the table of local NVMe paths (`$NVME_DIR/<service>/<role>`, see Storage) and `deploy.sh`'s guard; `scripts/migrate-nvme-layout.sh` moves the legacy paths into it
- `acme/acme.json` — Let's Encrypt certs (Traefik-managed, chmod 600)
- `dolt/` — **templates** for the Dolt server YAML and the beads-user init script (the live copies are on the NAS), plus `RESTORE.md` (restore procedure)
- `scripts/dolt-add-db.sh` — create one Beads database and grant `beads` on it (no global grants)
- `scripts/validate-dolt.sh` — Dolt validation script (TLS, logins, init, NAS config drift)

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `DOMAINNAME` | Primary domain for all subdomains |
| `CLOUDFLARE_EMAIL` | Let's Encrypt account email (ACME registration) |
| `CLOUDFLARE_DNS_API_TOKEN` | DNS challenge: Cloudflare API token from the "Edit zone DNS" template, scoped to `DOMAINNAME`'s zone only. Passed to Traefik as the compose secret `cloudflare_dns_api_token` (`CF_DNS_API_TOKEN_FILE`). Never the Global API Key, which has full account access |
| `CLOUDFLARE_ZONEID` | Zone ID (not referenced by compose) |
| `DOCKERDIR` | NFS mount path (e.g. `/mnt/docker`) |
| `LOCALDOCKERDIR` | Local storage path (`/home/jalance/Projects/docker-services`, on the 1TB TeamGroup SATA SSD that replaced the failed 870 EVO on 2026-10-17). See `REBUILD.md` §5 |
| `NVME_DIR` | Optional. Parent of the local NVMe paths (default `/usr/local/docker`, see Storage). Not `LOCALDOCKERDIR` |
| `SYNOLOGYDIR` | Synology NAS mount |
| `CROWDSEC_BOUNCER_KEY` | Traefik-to-CrowdSec bouncer key (`openssl rand -hex 32`); passed to both CrowdSec (registers it as bouncer `traefik`) and Traefik as the compose secret `crowdsec_bouncer_key` |
| `HOST_IP` | **Not in `.env`: derived at every compose run** by `scripts/lib/host-addrs.sh` (source address of the main table's IPv4 default route; exactly one default route required). Host LAN IP: local resolution in the validate scripts, and the only address Pi-hole binds :53 and Dolt :3307 on (required by compose) |
| `TAILSCALE_IP` | **Not in `.env`: derived** the same way, from `tailscale ip -4`. Optional: if it cannot be derived it is `127.0.0.1` with a warning, so deploys still run and Dolt is LAN-only until the next deploy after `tailscaled` is back. Only Dolt uses it |
| `DOLT_BEADS_PASSWORD` | Password for the Dolt user `beads` (`openssl rand -hex 32`). Compose secret `dolt_beads_password`, not a container env var |
| `PLEX_TOKEN` | Plex auth token (used by Kometa) |
| `TMDB_API_READ_ACCESS_TOKEN` | TMDb v4 read token (used by Kometa) |

**Run compose by hand as `./scripts/compose.sh <args>`**, never bare `docker compose`: compose requires `HOST_IP`/`TAILSCALE_IP` for every command (even `ps`), and the wrapper derives them from the host first (`scripts/lib/host-addrs.sh`). It fails loudly if it cannot derive `HOST_IP`; there is no fallback to `0.0.0.0`. Tailscale being down never blocks compose (see the table). `deploy.sh`, `scripts/ci/integration-run.sh`, the validate scripts and the `dolt-*` scripts use the same helper. The derived values override any left in `.env`, and the helper warns while `.env` still sets them.

## Adding New Services

1. Add service to `docker-compose.yml` using an existing service (e.g. radarr) as a template
2. Connect to `t2_proxy` network
3. Add Traefik labels: `traefik.http.routers.<name>.rule=Host(\`<name>.$DOMAINNAME\`)`
4. Use `chain-authelia@file` middleware. `chain-authelia`, `chain-no-auth` and `chain-basic-auth` all start with `crowdsec@file`, so a new service gets the WAF automatically. Never attach a router without one of these chains — it would bypass CrowdSec.
5. Add NFS volume if config persistence needed (follow existing pattern, Synology at 192.168.0.6).
   If it needs the local NVMe instead (an embedded database, or speed), mount `${NVME_DIR:-/usr/local/docker}/<service>/<role>`
   and add a row to `NVME_PATHS` in `scripts/lib/nvme-paths.sh` (`./scripts/ci/test-nvme-paths.sh` fails until both agree)
6. Add subdomain to `SERVICES` array in `scripts/validate-traefik.sh`
7. Run `./scripts/validate-traefik.sh`

## Validation

**Always run after modifying `docker-compose.yml`:**

```bash
./scripts/validate-traefik.sh
```

Checks HTTPS access, HTTP→HTTPS redirect, security headers, TLS cert, and Traefik API for all services.

Also run `./scripts/validate-waf.sh` after changes touching Traefik, CrowdSec or the chains (containers up, bouncer pulling, `/.env` probe blocked, normal page allowed).

Run `./scripts/validate-dolt.sh` after changes touching Dolt, its NAS config or its certs (healthy; TLS verifies for `dolt.<domain>` on `HOST_IP` and `TAILSCALE_IP`; plaintext and remote `root` rejected; `beads` logs in over verified TLS; init did not rerun; the NAS `servercfg/config.yaml` and `init/01-beads-user.sh` match `dolt/`). Its MySQL client is a pinned image run with `docker run --rm --network host`; it also does the TLS check (`VERIFY_IDENTITY` with a non-existent user: `Access denied` means the handshake verified). `openssl s_client -starttls mysql` does not handshake with Dolt (`MySQL packet too short`) yet prints `Verify return code: 0 (ok)`, so it cannot be used.

## Logging

All containers use `*default-logging` (json-file, 10MB max, 3 files). Application-level logs on NFS have built-in rotation — do not add external logrotate.

Traefik's access log is the exception: it goes to a file (`$LOCALDOCKERDIR/traefik-logs/access.log`, full log, no status filter), not stdout, so it no longer
appears in `docker logs traefik`. task-scheduler rotates it daily at 00:10 (`traefik-logrotate.sh`, copytruncate: `cp -p` to `access.log.<YYYYmmdd-HHMMSS>`, then truncate `access.log` in place; no signal, no Docker access, and `access.log` never disappears). This is safe because Traefik opens the file `O_APPEND` (`openAccessLogFile`, v3.6), verified by truncating the live file: it restarted at 411 bytes, no NUL bytes. CrowdSec re-opens the truncated file (`Re-opening truncated file`) and keeps reading. Retention is the current file + 2 rotated (newest 2 by name). A line written between the copy and the truncate is missing from the archive only; CrowdSec reads it as it is written.
The full log is **sensitive**: it records query strings, so API keys passed as `?apikey=` (*arr, hydra) are stored in clear text, `root:root` 0644, in `$LOCALDOCKERDIR/traefik-logs` (dir mode 700, owned by `jalance`; containers run as root; the rotation job re-enforces 700 every run).

## Git Workflow

**Never commit directly to master.** Always use a feature branch, push, and open a PR.

**A PR is not done until its checks pass.** After `gh pr create` (and after every later push to the branch), run
`gh pr checks <n> --watch` and confirm `gh pr view <n> --json mergeStateStatus` is `CLEAN`. On a failure, read the
log (`gh run view <run> --log-failed`), fix it, push, and watch again. Never report a PR as ready while a check is failing or pending.

**Before post-merge cleanup** (pull master, delete branches), confirm `gh pr view <n> --json state` is `MERGED`.
`gh pr view` exits 0 for an open PR too, so its exit code proves nothing.

**CI has no `.env`.** The "Validate docker-compose.yml" step in `.github/workflows/lint.yml` supplies a dummy value for
every required `${VAR:?}` in compose. A new required variable needs a dummy value there too, or CI fails.

## Notes

- **Plex**: LinuxServer.io image with `/dev/dri` GPU transcoding; `VERSION=public` enables auto-updates on container restart
- **Task Scheduler**: Docker cleanup nightly at midnight; Plex restart Sundays at 3 AM
- **Kometa**: Runs daily at 1 AM; reads `PLEX_TOKEN` and `TMDB_API_READ_ACCESS_TOKEN` from env; config at `/mnt/docker/kometa/config.yml`
- **NZBHydra2 (hydra)**: H2 database lives on local NVMe at `$NVME_DIR/nzbhydra2/database`, *not* NFS.
  The Synology periodically revokes NFSv4 lock state (`NFS: : lost 3 locks` in `dmesg`, ~every 9 days);
  the kernel surfaces that as EIO (`recover_lost_locks` is off by default), and H2 treats any I/O error as
  fatal with no reopen path, so one blip wedges the DB until the container restarts
  ([h2database#1954](https://github.com/h2database/h2database/issues/1954), open since 2019). SQLite-based
  services tolerate this; H2 does not. `stop_grace_period: 120s` is required so H2 can compact on shutdown.
  The path is not independently configurable — H2's URL is `${nzbhydra.dataFolder}/database/nzbhydra` — hence
  the nested mount.
- **Pi-hole**: Host port 53, bound to `$HOST_IP` only (not `0.0.0.0`). No systemd-resolved conflict — `DNSStubListener=no` is already set in
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
- **CrowdSec** (WAF): Traefik plugin `crowdsec@file` (defined in `traefik-rules/crowdsec.yml`; see Traefik file rules below) does stream-mode bans (LAPI `crowdsec:8080`, refresh 60s) and AppSec (`crowdsec:7422`)
  on each request. AppSec runs 4 runners (`routines: 4` in `acquis.d/appsec.yaml`; the default is 1, which serialises every request). Config + DB on local disk (see Storage); `acquis.d/` is tracked and mounted read-only.
  - **Fails open on purpose** (Authelia is still the auth layer): `updateMaxFailure=-1` (the default `0` would block *all* traffic once the LAPI is unreachable in stream mode),
    `streamStartupBlock=false` (Traefik does not wait for CrowdSec at start, so banned IPs pass for ~60s until the first sync), and AppSec unreachable / failure pass. **Unreadable bodies block** (plugin default, POST/PUT/PATCH/DELETE only; GET/HEAD go header-only and pass): HTTP/2/3 requests without Content-Length would otherwise reach AppSec header-only and skip body inspection. `crowdsecAppsecUnreadableBodyBlock=true` is the plugin default, pinned explicitly. `httpTimeoutSeconds` is the plugin default (10s): with fail-open a timed-out AppSec call passes the request uninspected, so a short timeout would let an attacker pad a body to exceed it; the cost is up to 10s of added latency if CrowdSec is slow (not down).
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
  - **Operate**: `./scripts/compose.sh exec crowdsec cscli decisions list` / `alerts list` / `metrics show appsec`. Unban: `./scripts/compose.sh exec crowdsec cscli decisions delete --ip <ip>`
    (takes effect within ~60s, the stream refresh). Stale `traefik@<ip>` bouncers (one is added each time Traefik connects from a new IP): `cscli bouncers delete traefik` removes `traefik` **and every `traefik@<ip>`, including the live one**, so follow it with `./scripts/compose.sh restart crowdsec`, which re-registers `traefik` from the secret. Until then the key is unregistered (`cscli bouncers list` is empty), and a wrong or unregistered key blocks every chained router with 403 (the LAPI stream fails open, but AppSec answers an unknown key with 401, and the plugin blocks on any AppSec error other than 500/502/503/504/unreachable): an outage, so run the restart immediately.
  - **Docker access**: none. CrowdSec is on `t2_proxy` only, not on `socket_proxy`, and has no socket mount.
  - **Ping**: `/ping` is on an unpublished `ping` entrypoint (`:8082`); there is no `traefik` entrypoint / published `:8080` any more (`api.insecure` is off, the API is served by `traefik-rtr`); `http`, `https` and `dsm-admin` are set `asDefault=true` so `ping` does not become a default entrypoint for routers without explicit entryPoints. The healthcheck must repeat `--ping.entryPoint=ping --entryPoints.ping.address=:8082`
    because `traefik healthcheck` does not read the daemon's flags.
  - **Bouncer key rotation**: a wrong or unregistered key blocks every chained router with 403 (the LAPI stream fails open, but AppSec answers an unknown key with 401, and the plugin blocks on any AppSec error other than 500/502/503/504/unreachable), i.e. a key mismatch is an outage, not a silent fail-open; an *empty* key fails closed (`docker compose config` refuses to render without it via `x-require-crowdsec-bouncer-key`; `validate-waf.sh` also checks). Procedure: `REBUILD.md` §7.
  - **Rollback**: revert the PR. The pre-WAF rules are kept, unused, on NFS at `/mnt/docker/traefik3/rules/` (chains without `crowdsec@file`), and a revert points Traefik back there. Keep that directory until the WAF has proven stable. Merge procedure: `REBUILD.md` §7.
  - **Bypass**: file-provider router `dsm-photo-rtr` (`traefik-rules/synology.yml`, `home.<domain>/photo` to Synology :80) has no middlewares and no entryPoints, so it skips CrowdSec and Authelia on all default entrypoints (`http`, `https`, `dsm-admin`).
    Pre-existing, not changed (`REBUILD.md` §8). Also outside the chains: `http-catchall` (redirect to HTTPS only, no backend) and the DSM TCP passthrough routers `grond-https-rtr`/`grond-admin-rtr` in the same file (TCP, so no HTTP middleware applies).
  - **Traefik file rules**: all in `traefik-rules/`, mounted read-only at `/rules` as a **directory** (a single-file bind mount pins the inode and goes stale when git/an editor replaces the file). `--providers.file.watch=false` on purpose: the directory is this git checkout, where feature branches are developed, so a watch would put every `git switch` live (verified: a watched change applied within 3s), and a switch to a commit without `traefik-rules/` deletes the directory, leaving the bind mount pointing at a deleted inode. Unwatched, Traefik keeps what it loaded at start, and rule changes go live on merge: `deploy.sh` runs `docker compose restart traefik` when anything in `traefik-rules/` is newer than Traefik's last start (`up -d` alone would not recreate traefik), so rules from a failed deploy or a commit made without a restart are applied on the next deploy. Never switch this checkout to a commit without `traefik-rules/` (pre-merge `master`, old tags): it deletes the directory, and if Traefik starts meanwhile docker recreates it empty and root-owned, so Traefik comes up without the chains. The restart also re-binds the mount. Cost: ~2s connection refused per rules deploy.
    They used to live on NFS at `/mnt/docker/traefik3/rules/`, untracked and not reloaded (no inotify); that directory is now only the rollback copy (see Rollback). The middleware lives in the file provider (not Docker labels) on purpose: the docker provider skips containers that are not `healthy`, `traefik` itself included (`keepContainer`, `pkg/provider/docker/config.go`, v3.6),
    so a label-defined `crowdsec@docker` did not exist until the first healthcheck passed and every chained router 404ed (~2s even with `start_interval: 1s`, ~4.5s before). Label-defined config on `traefik` (`traefik-rtr`, `redirect-to-https`) is still subject to that gap.
    Measured with `restart traefik` (probe every 0.25s x 120): labels, before `start_interval`: 16x404 + 7x000; labels + `start_interval: 1s`: 7x404 + 8x000; `crowdsec@file`: 0x404, 7x000 (~2s connection refused during the process restart) and no `does not exist` errors in the log.
  - **Tainted collections**: `cscli collections list` shows `appsec-crs`, `base-http-scenarios` and `traefik` as `enabled,tainted`. Cause (`cscli collections inspect`, `tainted_by`): `DISABLE_SCENARIOS` removes
    `crowdsec-appsec-outofband` and `http-crawl-non_statics`, which those collections contain, and `traefik` is tainted via `base-http-scenarios`. Consequence: tainted items are skipped by hub upgrades, so those three collections do not update until the scenarios are re-enabled.
  - **Follow-ups / out of scope** (DSM TCP passthrough, CRS in-band, Authelia log acquisition, Cloudflare `trustedIPs`): see `REBUILD.md` §8.
- **Dolt** (Beads): `dolthub/dolt-sql-server:2.6.1`, MySQL protocol, TLS required, no Traefik/Authelia. Publishes `:3307` on `$HOST_IP` and `$TAILSCALE_IP`, never `0.0.0.0`; the tailnet ACL decides which tailnet devices reach it (grokbot-box, `tag:grokbot`: orcrist tcp 22/445/3307). If `tailscaled` is down when the container starts (e.g. at boot), Docker cannot bind `$TAILSCALE_IP` and dolt does not start; nothing orders the two. Compose runs (deploys included) never fail on Tailscale: while it is down the helper binds `127.0.0.1` instead and warns, so a deploy brings dolt back LAN-only, and the next deploy after `tailscaled` returns restores the tailnet address.
  Clients use `dolt.<domain>`: a DNS-only CNAME to `orcrist.<domain>` (A `$HOST_IP`), covered by the `*.<domain>` wildcard. It may be repointed, so clients never hardcode `orcrist`. Tailscale clients connect to `$TAILSCALE_IP` with TLS server name `dolt.<domain>` (an `/etc/hosts` entry), never skip-verify.
  - **Config stays on the NAS, not in git.** `servercfg/`, `init/`, `certs/` and `backups/` on `dolt_config` (`/mnt/docker/dolt`). Compose mounts each one by volume `subpath` at the path the image reads: `/etc/dolt/servercfg.d`, `/docker-entrypoint-initdb.d` and `/certs` read-only, and `/backups`. `dolt/` in this repo holds **templates** only, copied by hand like `kometa/config.yml.example`, because the repo is public and live config can be identifying. A merged template change does not deploy: copy it to the NAS, then `./scripts/compose.sh restart dolt`. Drift cannot pass silently: `deploy.sh` refuses to deploy (before touching any container) and `validate-dolt.sh` fails while `servercfg/config.yaml` or `init/01-beads-user.sh` on the NAS differs from its template, and both print the `diff`/`cp` commands (`scripts/lib/dolt-nas.sh`, read-only). A PR that changes a template therefore fails its `dolt` integration check, and its merge deploy, until the NAS copy is updated.
  - **Data**: `$NVME_DIR/dolt/data` → `/var/lib/dolt`. That is the image's `VOLUME`, and its entrypoint hardcodes `/var/lib/dolt/.init_completed`. A hydra-style nested `data_dir` made every start look like a first run. Init (`01-beads-user.sh`) runs only while that marker is missing.
  - **Entrypoint guard** (inline in compose, then `exec tini -- docker-entrypoint.sh`). Whenever `servercfg.d` does not hold exactly one `*.yaml`, the image starts on its defaults: plaintext on `0.0.0.0`, with the existing users. The guard refuses to start unless these exist: `config.yaml` with `require_secure_transport: true`, both PEMs, and, on a first start, the init script.
  - **Certs**: `dolt-certs.sh` (task-scheduler, at its start and daily at 00:20) dumps the wildcard from `acme.json` into `certs/` and restarts dolt only when the cert changed. The restart is `POST /containers/dolt/restart`: `CONTAINERS=1` and `POST=1` allow it, `EXEC` is off.
  - **Privileges**: the users are `beads@'192.168.0.%'` and `beads@'100.%'`. MySQL host patterns cannot express Tailscale's `100.64.0.0/10`, so `100.%` is wider. `beads` has no `*.*` grants: Dolt 2.6.1 ignores database-name wildcards, and a global grant can `UPDATE mysql.user` and move `root` off localhost (verified). `./scripts/dolt-add-db.sh <prefix>` creates one database and grants it. `bd init --external` against that pre-created database is UNVERIFIED. `secure_file_priv=/secure-priv` (empty tmpfs), because otherwise `LOAD_FILE` can read the secret.
  - **Backup**: `scripts/dolt-prebackup.sh` overwrites `backups/` on the NAS (latest only): a native `dolt_backup`, a SQL dump and a grants transcript. It runs from jalance's crontab at 03:00 America/Denver (`REBUILD.md` §1). It is not in task-scheduler because it needs `docker exec`, and socket-proxy `EXEC` stays off. Restore: `dolt/RESTORE.md`.
- **Home Assistant**: Privileged mode with host network (required for device access)
