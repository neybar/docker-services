# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a home server Docker infrastructure repository that orchestrates self-hosted services using Docker Compose behind a Traefik reverse proxy with Authelia SSO/2FA authentication.

## Common Commands

```bash
# Start all services
docker compose up -d

# Start specific service
docker compose up -d <service-name>

# View logs
docker compose logs -f <service-name>

# Restart a service
docker compose restart <service-name>

# Stop all services
docker compose down
```

## Architecture

### Network Topology
- **t2_proxy** (192.168.90.0/24): Main network for Traefik and web-accessible services
- **socket_proxy** (192.168.91.0/24): Isolated network for Docker Socket Proxy access only

### Security Stack
1. **Traefik** - Reverse proxy with automatic Let's Encrypt certificates via Cloudflare DNS challenge
2. **Docker Socket Proxy** - Restricts Docker API access (never expose Docker socket directly)
3. **Authelia** - SSO/2FA protecting external access via Traefik middleware chains

### Storage Strategy
- **NFS volumes** (Synology NAS at 192.168.0.6): Service configurations for backup/persistence
- **Local NVME** (/usr/local/plex, /tmp/plex_transcode): High-performance storage for Plex transcoding

### Service Categories
- **Infrastructure**: Traefik, Docker Socket Proxy, Authelia, Portainer, Docker-GC
- **Media**: Plex (GPU-enabled), Sonarr, Radarr, Bazarr, SABnzbd, NZBHydra2
- **Books**: Calibre-Web, Lazy Librarian
- **DNS/Ad-blocking**: Pi-hole (port 53)
- **Home Automation**: Home Assistant (privileged, host network)
- **Dashboard**: Organizr

## Key Configuration Files

- `docker-compose.yml` - Main service definitions
- `env.example` - Required environment variables template (copy to `.env`)
- `acme/acme.json` - Let's Encrypt certificates (Traefik managed)
- `pihole/` - Pi-hole DNS configuration
- `docker-gc/` - Garbage collection exclusion rules

## Environment Variables

Critical variables in `.env`:
- `DOMAINNAME` - Primary domain for all service subdomains
- `CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_KEY`, `CLOUDFLARE_ZONEID` - DNS challenge auth
- `DOCKERDIR` - NFS-mounted config directory
- `LOCALDOCKERDIR` - Local (non-NFS) docker directory
- `SYNOLOGYDIR` - Synology mount path for media volumes
- `HOST_IP` - Used for DSM admin access through Traefik

## Adding New Services

1. Add service definition to `docker-compose.yml`
2. Connect to `t2_proxy` network for web access
3. Add Traefik labels for routing: `traefik.http.routers.<name>.rule=Host(\`<name>.$DOMAINNAME\`)`
4. Use `chain-authelia@file` middleware for authentication
5. Create NFS volume in volumes section if config persistence needed
6. Reference existing services (e.g., sonarr, radarr) as templates

## Notes

- Pi-hole runs on host port 53 - may conflict with systemd-resolved
- Plex uses `/dev/dri` for GPU transcoding
- Home Assistant runs privileged with host network for device access
- Docker-GC runs daily at midnight with 7-day grace period
