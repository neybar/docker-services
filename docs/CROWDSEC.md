# CrowdSec WAF and Traefik file rules

How the CrowdSec WAF in front of every HTTP service works, why it is configured the way it is, and how to operate it.
Bring-up and bouncer-key rotation: `REBUILD.md` §7. The short rules for agents are in `AGENTS.md`.

## Overview

Request path: Traefik → `crowdsec@file` (bans + AppSec WAF) → Authelia (`chain-authelia@file`) → service.

- The Traefik plugin `crowdsec@file` (defined in `traefik-rules/crowdsec.yml`) does stream-mode bans (LAPI
  `crowdsec:8080`, refresh 60s) and AppSec (`crowdsec:7422`) on each request.
- It is the **first entry of every middleware chain** (`traefik-rules/middleware-chains.yml`: `chain-authelia`,
  `chain-no-auth`, `chain-basic-auth`), so banned IPs and attack payloads are stopped before Authelia.
- AppSec runs 4 runners (`routines: 4` in `crowdsec-config/acquis.d/appsec.yaml`; the default is 1, which serialises
  every request).
- Config + SQLite DB are on local disk at `$LOCALDOCKERDIR/crowdsec/{config,data}` (gitignored, regenerable: losing it
  loses only decisions/alerts history). `crowdsec-config/acquis.d/` (`traefik.yaml`, `appsec.yaml`) is tracked and
  mounted read-only.
- CrowdSec reads Traefik's access log (`$LOCALDOCKERDIR/traefik-logs/access.log`; rotation: `REBUILD.md` §7).

## Routers outside the chains

- **Bypass**: file-provider router `dsm-photo-rtr` (`traefik-rules/synology.yml`, `home.<domain>/photo` to Synology
  :80) has no middlewares and no entryPoints, so it skips CrowdSec and Authelia on all default entrypoints (`http`,
  `https`, `dsm-admin`). Pre-existing, not changed (Beads `ds-o9h`).
- `http-catchall`: redirect to HTTPS only (`redirect-to-https`), no backend.
- The DSM TCP passthrough routers `grond-https-rtr`/`grond-admin-rtr` in the same file: TCP, so no HTTP middleware
  applies (Beads `ds-0lu`).

## Fails open on purpose

Authelia is still the auth layer, so CrowdSec being down must not take the stack down.

- `updateMaxFailure=-1`: the default `0` would block *all* traffic once the LAPI is unreachable in stream mode.
- `streamStartupBlock=false`: Traefik does not wait for CrowdSec at start, so banned IPs pass for ~60s until the first
  sync.
- AppSec unreachable / failure: pass.
- **Unreadable bodies block** (plugin default, POST/PUT/PATCH/DELETE only; GET/HEAD go header-only and pass): HTTP/2/3
  requests without Content-Length would otherwise reach AppSec header-only and skip body inspection.
  `crowdsecAppsecUnreadableBodyBlock=true` is the plugin default, pinned explicitly.
- `httpTimeoutSeconds` is the plugin default (10s): with fail-open a timed-out AppSec call passes the request
  uninspected, so a short timeout would let an attacker pad a body to exceed it. The cost is up to 10s of added latency
  if CrowdSec is slow (not down).

Verified: crowdsec stopped 100s, services kept answering, `/.env` was not blocked.

### Bouncer key: a mismatch is an outage, not a fail-open

`CROWDSEC_BOUNCER_KEY` is passed to both CrowdSec (registers it as bouncer `traefik`) and Traefik as the compose secret
`crowdsec_bouncer_key`.

- A **wrong or unregistered** key blocks every chained router with 403: the LAPI stream fails open, but AppSec answers
  an unknown key with 401, and the plugin blocks on any AppSec error other than 500/502/503/504/unreachable.
  `validate-waf.sh` detects it (the normal-page check fails).
- An **empty** key fails closed: `docker compose config` refuses to render without it (`x-require-crowdsec-bouncer-key`),
  and `validate-waf.sh` also checks.
- Rotation procedure: `REBUILD.md` §7.

## Whitelisting

Parser `crowdsecurity/whitelists` (127/8, 10/8, 172.16/12, 192.168/16, ::1) suppresses *bans* for LAN and docker nets.
It does **not** exempt AppSec *blocking*: a LAN `/.env` probe gets 403 and an alert, no ban. Tests from this host
therefore see 403s.

## Rules and scenarios

- `appsec-default` (virtual patching + generic rules) blocks inline.
- OWASP CRS (`crowdsecurity/crs`) runs **out-of-band only**: alerts only, no inline blocks and no bans.
- **Disabled scenarios** (`DISABLE_SCENARIOS` in compose, space-separated):
  - `crowdsecurity/crowdsec-appsec-outofband`: CRS's ban scenario, off until CRS is tuned. Re-enabling it, and later
    `crs-inband`, is Beads `ds-vhq`. Do not add either casually.
  - `crowdsecurity/http-crawl-non_statics`: with the full access log, one *arr/Organizr page load makes many
    non-static requests, so it would ban our own WAN IP for 4h.
  - Other `base-http-scenarios` stay on.
- **Tainted collections**: `cscli collections list` shows `appsec-crs`, `base-http-scenarios` and `traefik` as
  `enabled,tainted`. Cause (`cscli collections inspect`, `tainted_by`): `DISABLE_SCENARIOS` removes
  `crowdsec-appsec-outofband` and `http-crawl-non_statics`, which those collections contain, and `traefik` is tainted
  via `base-http-scenarios`. Consequence: tainted items are skipped by hub upgrades, so those three collections do not
  update until the scenarios are re-enabled.

## Authelia logs are not read by CrowdSec

The only way without a log file was Docker API access, and the tecnativa socket-proxy cannot scope that below "read
every container's env and filesystem" (`CONTAINERS=1` exposes `/containers/*/json` and `/archive`, i.e. TLS keys and
other containers' env). Brute force on Authelia is covered by Authelia's own `regulation:` (max_retries 3, find_time
120, ban_time 300, in `/mnt/docker/authelia/configuration.yml`). Follow-up: Beads `ds-zxh`.

**Docker access**: none. CrowdSec is on `t2_proxy` only, not on `socket_proxy`, and has no socket mount.

## CAPI and versions

- **CAPI**: default registration is on. This pulls the community blocklist and shares your attacker IPs with CrowdSec.
  The console is not enrolled (optional manual `cscli console enroll`).
- **Versions**: image pinned to `v1.8.1`; the bouncer plugin is pinned and vendored (bump: `plugins-local/README.md`).
  Hub collections are **not** version-pinned and update with the image/hub.

## Operate

```bash
./scripts/compose.sh exec crowdsec cscli decisions list
./scripts/compose.sh exec crowdsec cscli alerts list
./scripts/compose.sh exec crowdsec cscli metrics show appsec
./scripts/compose.sh exec crowdsec cscli decisions delete --ip <ip>   # unban; takes effect within ~60s (stream refresh)
```

**Stale `traefik@<ip>` bouncers** (one is added each time Traefik connects from a new IP): `cscli bouncers delete
traefik` removes `traefik` **and every `traefik@<ip>`, including the live one**, so follow it immediately with
`./scripts/compose.sh restart crowdsec`, which re-registers `traefik` from the secret. Until then the key is
unregistered (`cscli bouncers list` is empty) and every chained router returns 403 (see the bouncer key above): an
outage.

Validate after changes touching Traefik, CrowdSec or the chains: `./scripts/validate-waf.sh` (containers up, bouncer
pulling, `/.env` probe blocked, normal page allowed).

## Ping and entrypoints

`/ping` is on an unpublished `ping` entrypoint (`:8082`). There is no `traefik` entrypoint / published `:8080` any more
(`api.insecure` is off, the API is served by `traefik-rtr`). `http`, `https` and `dsm-admin` are set `asDefault=true`
so `ping` does not become a default entrypoint for routers without explicit entryPoints. The healthcheck must repeat
`--ping.entryPoint=ping --entryPoints.ping.address=:8082` because `traefik healthcheck` does not read the daemon's
flags.

## Traefik file rules (`traefik-rules/`)

All Traefik file-provider config lives in `traefik-rules/`: `middleware-chains.yml`, `middlewares.yml`, `crowdsec.yml`
and the routers for services outside compose (`homebridge.yml`, `synology.yml`). The domain is written as
`{{ env "DOMAINNAME" }}` (Go template; `DOMAINNAME` is passed to the traefik container).

- **Mounted read-only at `/rules` as a directory.** A single-file bind mount pins the inode and goes stale when git or
  an editor replaces the file.
- **Not watched** (`--providers.file.watch=false`) on purpose: the directory is the git checkout, where feature branches
  are developed, so a watch would put every `git switch` live (verified: a watched change applied within 3s), and a
  switch to a commit without `traefik-rules/` deletes the directory, leaving the bind mount pointing at a deleted inode.
  Unwatched, Traefik keeps what it loaded at start, and rule changes go live on merge: `deploy.sh` runs
  `docker compose restart traefik` when anything in `traefik-rules/` is newer than Traefik's last start (`up -d` alone
  would not recreate traefik), so rules from a failed deploy or a commit made without a restart are applied on the next
  deploy. By hand: `./scripts/compose.sh restart traefik`. The restart also re-binds the mount. Cost: ~2s connection
  refused per rules deploy.
- **Never switch the deploy checkout to a commit without `traefik-rules/`** (old tags, history before the WAF): it
  deletes the directory, and if Traefik starts meanwhile docker recreates it empty and root-owned, so Traefik comes up
  without the chains.
- History: the rules used to live on NFS at `/mnt/docker/traefik3/rules/`, untracked and not reloaded (no inotify).
  That copy (chains without `crowdsec@file`) is no longer used; deleting it is Beads `ds-a6m`. Rollback of a bad rules
  change is a revert on `master` (`docs/DEPLOY.md`).

### Why the middleware is in the file provider, not Docker labels

The docker provider skips containers that are not `healthy`, `traefik` itself included (`keepContainer`,
`pkg/provider/docker/config.go`, v3.6), so a label-defined `crowdsec@docker` did not exist until the first healthcheck
passed, and every chained router 404ed (~2s even with `start_interval: 1s`, ~4.5s before). Label-defined config on
`traefik` (`traefik-rtr`, `redirect-to-https`) is still subject to that gap.

Measured with `restart traefik` (probe every 0.25s x 120):

| Variant | Result |
|---|---|
| labels, before `start_interval` | 16x404 + 7x000 |
| labels + `start_interval: 1s` | 7x404 + 8x000 |
| `crowdsec@file` | 0x404, 7x000 (~2s connection refused during the process restart), no `does not exist` errors in the log |

## Out of scope / follow-ups

DSM TCP passthrough (`ds-0lu`), `dsm-photo-rtr` (`ds-o9h`), CRS in-band (`ds-vhq`), Authelia log acquisition
(`ds-zxh`), Cloudflare `trustedIPs` (`ds-5gn`), WAN ban test (`ds-5fh`), browser checks (`ds-qix`). See
`REBUILD.md` §8.
