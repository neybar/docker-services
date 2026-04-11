# Home Server Docker Stack

Self-hosted services running on Docker Compose behind Traefik with Authelia SSO/2FA and a Synology NAS for storage.

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
| Infrastructure | Task Scheduler | internal only |
| Dashboard | Organizr | `start.$DOMAINNAME` |
| Media | Plex | `plex.$DOMAINNAME` |
| Media | Sonarr | `sonarr.$DOMAINNAME` |
| Media | Radarr | `radarr.$DOMAINNAME` |
| Media | Bazarr | `bazarr.$DOMAINNAME` |
| Media | SABnzbd | `sabnzb.$DOMAINNAME` |
| Media | NZBHydra2 | `hydra.$DOMAINNAME` |
| Collection Mgmt | Kometa | `kometa.$DOMAINNAME` |
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
- `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ZONEID` — for Let's Encrypt DNS challenge
- `DOCKERDIR` — NFS mount path (e.g. `/mnt/docker`)
- `LOCALDOCKERDIR` — local project directory path
- `PLEX_TOKEN` — required for Kometa (get from Plex account settings)
- `TMDB_API_READ_ACCESS_TOKEN` — required for Kometa (TMDb v4 read token)

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
- **Daily at 1 AM**: Kometa runs and updates Plex collections

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for the automated task workflow using `ralph.sh`.
