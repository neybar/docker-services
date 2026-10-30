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
| Infrastructure | Dolt (Beads) | `beads.$DOMAINNAME:3307` LAN only, no Traefik |
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
| DNS | Pi-hole | `pihole.$DOMAINNAME/admin/` |
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
- `DOMAINNAME` — your domain (all services run as subdomains)
- `CLOUDFLARE_EMAIL` (Let's Encrypt account email), `CLOUDFLARE_DNS_API_TOKEN` (scoped "Edit zone DNS" token), `CLOUDFLARE_ZONEID` — for Let's Encrypt DNS challenge
- `DOCKERDIR` — NFS mount path (e.g. `/mnt/docker`)
- `LOCALDOCKERDIR` — local project directory path
- `PLEX_TOKEN` — required for Kometa (get from Plex account settings)
- `TMDB_API_READ_ACCESS_TOKEN` — required for Kometa (TMDb v4 read token)
- `CROWDSEC_BOUNCER_KEY` — Traefik/CrowdSec bouncer key (`openssl rand -hex 32`)
- `DOLT_BEADS_PASSWORD` — Beads SQL password (`openssl rand -hex 32`, hex only). Compose secret, not a container env var. See [dolt/RESTORE.md](dolt/RESTORE.md)

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
only as a failed renewal in `docker compose logs traefik`.

### 2. Docker Networks

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
docker compose up -d
```

## Maintenance

Task Scheduler handles routine maintenance automatically:
- **Nightly at midnight**: Docker cleanup (prunes images/containers/volumes older than 7 days)
- **Sundays at 3 AM**: Plex restart (picks up `VERSION=public` updates)
- **Daily at 00:10**: Traefik access log rotation (current file + 2 rotated kept)
- **Daily at 00:20**: Dolt certificate dump; Dolt restarts only when the cert changed
- **Daily at 02:15**: Dolt backup (local disk, then `/mnt/backups/dolt`)
- **Daily at 1 AM**: Kometa runs and updates Plex collections

## Dolt (Beads)

Shared Dolt sql-server for `bd` on several machines. Not behind Traefik. Checklist, grants, and restore steps: [dolt/RESTORE.md](dolt/RESTORE.md).

Before merging (deploy refuses to render without the password):

1. Set `DOLT_BEADS_PASSWORD` in orcrist's `.env` (`openssl rand -hex 32`).
2. `mkdir -p /mnt/backups/dolt`.
3. Decide the open questions in `dolt/RESTORE.md`: grey-cloud A record `beads` → `192.168.0.3` versus a NextDNS rewrite, and a Tailscale subnet route of `192.168.0.3/32` versus a hosts-file entry at orcrist's Tailscale IP.
4. After the container is up, `./scripts/dolt-add-db.sh <prefix>` for each Beads project, then `bd init --server --external` on the clients. Whether that init succeeds against the pre-created database was not executed here.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the automated task workflow using `ralph.sh`.
