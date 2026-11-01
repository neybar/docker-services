# Home Server Docker Stack

Self-hosted services running on Docker Compose behind Traefik with a CrowdSec WAF, Authelia SSO/2FA and a Synology NAS for storage.

## References

- [Traefik Docker tutorial](https://www.smarthomebeginner.com/traefik-2-docker-tutorial/)
- [Traefik docs](https://doc.traefik.io/traefik/)
- [Docker Compose reference](https://docs.docker.com/compose/compose-file)

## Services

| Category | Service | Subdomain |
|----------|---------|-----------|
| Infrastructure | Traefik | `traefik.$DOMAINNAME` |
| Infrastructure | Authelia | `authelia.$DOMAINNAME` |
| Infrastructure | Portainer | `portainer.$DOMAINNAME` |
| Infrastructure | Docker Socket Proxy | internal only |
| Infrastructure | CrowdSec (WAF) | internal only |
| Infrastructure | Task Scheduler | internal only |
| Infrastructure | Dolt (Beads) | `dolt.$DOMAINNAME:3307` on LAN and Tailscale, TLS only, no Traefik |
| Dashboard | Organizr | `start.$DOMAINNAME` |
| Media | Plex | `plex.$DOMAINNAME` |
| Media | Sonarr | `sonarr.$DOMAINNAME` |
| Media | Radarr | `radarr.$DOMAINNAME` |
| Media | Bazarr | `bazarr.$DOMAINNAME` |
| Media | SABnzbd | `sabnzb.$DOMAINNAME` |
| Media | NZBHydra2 | `hydra.$DOMAINNAME` |
| Collection Mgmt | Kometa | internal only (no web UI) |
| Books | Calibre-Web | `books.$DOMAINNAME` |
| Books | Lazy Librarian | `lazylib.$DOMAINNAME` |
| DNS | Pi-hole (cold standby) | `pihole.$DOMAINNAME/admin/`; DNS on `$HOST_IP:53` only |
| Home Automation | Home Assistant | `homeassistant.$DOMAINNAME` |
| Utilities | iSponsorBlockTV | internal only |
| Utilities | LibreSpeed | `speedtest.$DOMAINNAME` |
| Utilities | Smokeping | `smokeping.$DOMAINNAME` |
| Utilities | Slideshow Updater | internal only |

## Setup

### 1. Environment

```bash
cp env.example .env
# Fill in all values in .env
```

Key variables:

| Variable | Purpose |
|----------|---------|
| `DOMAINNAME` | Primary domain; every service is a subdomain |
| `CLOUDFLARE_EMAIL` | Let's Encrypt account email (ACME registration) |
| `CLOUDFLARE_DNS_API_TOKEN` | DNS challenge token from the "Edit zone DNS" template, scoped to `DOMAINNAME`'s zone only (below). Reaches Traefik as the compose secret `cloudflare_dns_api_token` (`CF_DNS_API_TOKEN_FILE`). Never the Global API Key |
| `CLOUDFLARE_ZONEID` | Zone ID (not referenced by compose) |
| `DOCKERDIR` | NFS mount path (e.g. `/mnt/docker`) |
| `LOCALDOCKERDIR` | The repo checkout (`/home/jalance/Projects/docker-services`, on the /home SATA SSD; `REBUILD.md` §5). Holds the gitignored local state: `acme/`, `crowdsec/`, `traefik-logs/`, `pihole/` |
| `NVME_DIR` | Optional. Parent of the local NVMe paths `$NVME_DIR/<service>/<role>` (default `/usr/local/docker`, on `/`; `REBUILD.md` §5). Not `LOCALDOCKERDIR` |
| `SYNOLOGYDIR` | Synology NAS mount |
| `CROWDSEC_BOUNCER_KEY` | Traefik↔CrowdSec bouncer key (`openssl rand -hex 32`). Passed to both as the compose secret `crowdsec_bouncer_key`; CrowdSec registers it as bouncer `traefik` ([docs/CROWDSEC.md](docs/CROWDSEC.md)) |
| `DOLT_BEADS_PASSWORD` | Password for the Dolt user `beads` (`openssl rand -hex 32`, hex only). Compose secret `dolt_beads_password`, not a container env var |
| `PLEX_TOKEN` | Plex auth token (used by Kometa; from Plex account settings) |
| `TMDB_API_READ_ACCESS_TOKEN` | TMDb v4 read token (used by Kometa) |
| `HOST_IP` | **Not in `.env`**: derived at every compose run by `scripts/lib/host-addrs.sh` (source address of the main table's IPv4 default route; exactly one default route required). The only address Pi-hole binds `:53` and Dolt `:3307` on; also used for local resolution by the validate scripts |
| `TAILSCALE_IP` | **Not in `.env`**: derived the same way, from `tailscale ip -4`. Optional: if it cannot be derived it is `127.0.0.1` with a warning, so deploys still run and Dolt is LAN-only until the next deploy after `tailscaled` is back. Only Dolt uses it |

The derived `HOST_IP`/`TAILSCALE_IP` override any left in `.env`, and the helper warns while `.env` still sets them.
Details: `REBUILD.md` §7, Host addresses.

#### Cloudflare DNS token (`CLOUDFLARE_DNS_API_TOKEN`)

Traefik uses this token to create the temporary `_acme-challenge` TXT record that proves domain ownership to
Let's Encrypt (wildcard cert, renewed ~30 days before expiry). It needs DNS edit on one zone and nothing else.
Do **not** use the Global API Key: it has full control of the whole Cloudflare account.

To create (or replace a lost) token:
1. Cloudflare dashboard → **My Profile → API Tokens → Create Token** → template **Edit zone DNS** → Use template.
2. **Permissions:** leave as `Zone / DNS / Edit`.
3. **Zone Resources:** `Include` → `Specific zone` → your `DOMAINNAME` zone.
4. Leave Client IP filtering and TTL empty (an expiring token silently breaks renewal months later) → Continue → Create Token.
5. Copy the value into `.env` as `CLOUDFLARE_DNS_API_TOKEN=`. Cloudflare shows it only once; if lost, roll or recreate it.
6. When replacing a token, delete the old one under My Profile → API Tokens.

Verify before starting Traefik (expect `"status":"active"` and only your zone listed):
```bash
# Read only this variable: sourcing .env breaks in zsh (it sets names zsh treats as special, e.g. GID)
T=$(grep '^CLOUDFLARE_DNS_API_TOKEN=' .env | cut -d= -f2-)
curl -s -H "Authorization: Bearer $T" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -c '{success, status: .result.status}'
curl -s -H "Authorization: Bearer $T" https://api.cloudflare.com/client/v4/zones | jq -c '[.result[].name]'
```

Compose refuses to start if the variable is empty. The token reaches Traefik as the compose secret
`cloudflare_dns_api_token` (`CF_DNS_API_TOKEN_FILE`), not as an env var. A bad token does not show up at startup,
only as a failed renewal in `./scripts/compose.sh logs traefik`.

### 2. Docker Networks

Both are external, so create them before the first run:
- `t2_proxy` (192.168.90.0/24): Traefik and every web-accessible service
- `socket_proxy` (192.168.91.0/24): isolated, Docker Socket Proxy only. Nothing gets the Docker socket directly, and
  CrowdSec has no Docker API access at all

```bash
docker network create --gateway 192.168.90.1 --subnet 192.168.90.0/24 t2_proxy
docker network create --gateway 192.168.91.1 --subnet 192.168.91.0/24 socket_proxy
```

### 3. Traefik

```bash
touch acme/acme.json
chmod 600 acme/acme.json
```

### 4. Kometa

Copy and configure the Kometa config on your NFS mount:
```bash
mkdir -p /mnt/docker/kometa/assets
cp kometa/config.yml.example /mnt/docker/kometa/config.yml
```

Token values are read from environment — no edits needed if `.env` is populated.

### 5. Portainer

After first start: Settings → Environments → Add Environment → Docker → set URL to `socket-proxy:2375`.

### 6. Start Everything

```bash
./scripts/compose.sh up -d
```

Use `./scripts/compose.sh` instead of `docker compose` for every compose command: it derives `HOST_IP` and
`TAILSCALE_IP` from the host first, and compose refuses to run without them.

## Maintenance

Task Scheduler handles routine maintenance automatically:
- **Nightly at midnight**: Docker cleanup (prunes images/containers/volumes older than 7 days)
- **Sundays at 3 AM**: Plex restart (picks up `VERSION=public` updates)
- **Daily at 00:10**: Traefik access log rotation (current file + 2 rotated kept)
- **Daily at 00:20**: Dolt certificate dump; Dolt restarts only when the cert changed
- **Daily at 03:00** (jalance's crontab, `CRON_TZ=America/Denver`): `scripts/dolt-prebackup.sh` overwrites a consistent snapshot on the NAS at `/mnt/docker/dolt/backups`
- **Daily at 1 AM**: Kometa runs and updates Plex collections

## Service notes

- **Plex**: LinuxServer.io image with `/dev/dri` GPU transcoding; `VERSION=public` updates it on every container
  restart. Its library database is on the local NVMe and in no backup (`REBUILD.md` §5-6).
- **Kometa**: runs daily at 1 AM; reads `PLEX_TOKEN` and `TMDB_API_READ_ACCESS_TOKEN` from the env; config at
  `/mnt/docker/kometa/config.yml` (template `kometa/config.yml.example`).
- **Home Assistant**: privileged, host network (needed for device access).
- **Pi-hole**: cold standby, v6 (`FTLCONF_*` env vars only); see `REBUILD.md` §2.
- **NZBHydra2**: its H2 database is on the local NVMe, not NFS (`REBUILD.md` §5).
- **Logging**: every container uses `*default-logging` (json-file, 10MB max, 3 files). Application logs on NFS rotate
  themselves; do not add an external logrotate. Exception: Traefik's access log (`REBUILD.md` §7).
- **CrowdSec WAF** and the Traefik file rules: [docs/CROWDSEC.md](docs/CROWDSEC.md).

## Dolt (Beads)

Shared Dolt sql-server for `bd` on several machines. Not behind Traefik. Its config lives on the NAS; `dolt/` holds
templates. Details: [dolt/README.md](dolt/README.md), restore: [dolt/RESTORE.md](dolt/RESTORE.md).

## Development

Changes go through a feature branch and a PR; a merge to `master` deploys ([docs/DEPLOY.md](docs/DEPLOY.md)).
Agent instructions (Claude Code, Codex, Cursor, Gemini): [AGENTS.md](AGENTS.md). Open work is tracked in Beads
(`bd ready`), on the shared Dolt server, not in markdown TODO files.
