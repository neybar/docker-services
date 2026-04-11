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
2. **Docker Socket Proxy** — Restricts Docker API access (never expose the socket directly)
3. **Authelia** — SSO/2FA on all external-facing services via `chain-authelia@file` middleware

### Storage
- **NFS volumes** (Synology at 192.168.0.6): Service configs and media libraries
- **Local NVME** (`/usr/local/plex`, `/tmp/plex_transcode`): Plex config and transcode scratch

### Services

| Category | Services |
|----------|----------|
| Infrastructure | Traefik, Socket Proxy, Authelia, Portainer, Task Scheduler |
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
- `acme/acme.json` — Let's Encrypt certs (Traefik-managed, chmod 600)

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `DOMAINNAME` | Primary domain for all subdomains |
| `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ZONEID` | DNS challenge |
| `DOCKERDIR` | NFS mount path (e.g. `/mnt/docker`) |
| `LOCALDOCKERDIR` | Local storage path (e.g. `/home/user/Projects/docker-services`) |
| `SYNOLOGYDIR` | Synology NAS mount |
| `HOST_IP` | Host IP for DSM access through Traefik |
| `PLEX_TOKEN` | Plex auth token (used by Kometa) |
| `TMDB_API_READ_ACCESS_TOKEN` | TMDb v4 read token (used by Kometa) |

## Adding New Services

1. Add service to `docker-compose.yml` using an existing service (e.g. radarr) as a template
2. Connect to `t2_proxy` network
3. Add Traefik labels: `traefik.http.routers.<name>.rule=Host(\`<name>.$DOMAINNAME\`)`
4. Use `chain-authelia@file` middleware
5. Add NFS volume if config persistence needed (follow existing pattern, Synology at 192.168.0.6)
6. Add subdomain to `SERVICES` array in `scripts/validate-traefik.sh`
7. Run `./scripts/validate-traefik.sh`

## Validation

**Always run after modifying `docker-compose.yml`:**

```bash
./scripts/validate-traefik.sh
```

Checks HTTPS access, HTTP→HTTPS redirect, security headers, TLS cert, and Traefik API for all services.

## Logging

All containers use `*default-logging` (json-file, 10MB max, 3 files). Application-level logs on NFS have built-in rotation — do not add external logrotate.

## Git Workflow

**Never commit directly to master.** Always use a feature branch, push, and open a PR.

## Notes

- **Plex**: LinuxServer.io image with `/dev/dri` GPU transcoding; `VERSION=public` enables auto-updates on container restart
- **Task Scheduler**: Docker cleanup nightly at midnight; Plex restart Sundays at 3 AM
- **Kometa**: Runs daily at 1 AM; reads `PLEX_TOKEN` and `TMDB_API_READ_ACCESS_TOKEN` from env; config at `/mnt/docker/kometa/config.yml`
- **Pi-hole**: Host port 53 — may conflict with systemd-resolved
- **Home Assistant**: Privileged mode with host network (required for device access)
