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
- **Infrastructure**: Traefik, Docker Socket Proxy, Authelia, Portainer, Task Scheduler
- **Media**: Plex (LinuxServer.io, GPU-enabled), Sonarr, Radarr, Bazarr, SABnzbd, NZBHydra2
- **Books**: Calibre-Web, Lazy Librarian
- **DNS/Ad-blocking**: Pi-hole (port 53)
- **Home Automation**: Home Assistant (privileged, host network)
- **Dashboard**: Organizr

## Key Configuration Files

- `docker-compose.yml` - Main service definitions
- `env.example` - Required environment variables template (copy to `.env`)
- `acme/acme.json` - Let's Encrypt certificates (Traefik managed)
- `pihole/` - Pi-hole DNS configuration
- `task-scheduler/` - Scheduled maintenance tasks (Docker cleanup, Plex restart)

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
7. Add the new service subdomain to `scripts/validate-traefik.sh` SERVICES array
8. Run the validation script (see Validation section below)

## Validation

**IMPORTANT: Always run the validation script after modifying `docker-compose.yml`.**

```bash
# Run validation (reads domain from .env)
./scripts/validate-traefik.sh

# Or specify domain explicitly
./scripts/validate-traefik.sh yourdomain.com
```

The script validates:
- All services are accessible via HTTPS
- HTTP to HTTPS redirect is working
- Security headers are present
- TLS certificate is valid
- Traefik dashboard and API are responding

When adding a new service, add its subdomain to the `SERVICES` array in `scripts/validate-traefik.sh`.

## Log Management

### Docker Container Logs (stdout/stderr)

All containers use standardized Docker logging with automatic rotation:
- **Driver**: json-file
- **Max size**: 10MB per log file
- **Max files**: 3 files retained
- **Total capacity**: ~30MB per container

Configuration is defined via YAML anchor in `docker-compose.yml`:
```yaml
x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

View container logs: `docker compose logs -f <service-name>`

### Application Logs (on NFS mount)

Many applications maintain their own logs on the NFS mount at `/mnt/docker/<service>/logs/`. These have **built-in rotation**:

| Application | Location | Rotation Method | Max Size |
|-------------|----------|-----------------|----------|
| **Radarr** | `/mnt/docker/radarr/logs/` | Built-in (1MB/file, ~25 files) | ~25-30MB |
| **Sonarr** | `/mnt/docker/sonarr/logs/` | Built-in (1MB/file, ~25 files) | ~25-30MB |
| **SABnzbd** | `/mnt/docker/sabnzb/logs/` | Configured (5MB max, 5 backups) | ~30MB |
| **NZBHydra2** | `/mnt/docker/hydra/logs/` | Date-based rotation | ~1MB |
| **Home Assistant** | `/mnt/docker/homeassistant/` | Python logging rotation | ~10MB |

**Log levels** are configured per application:
- Radarr/Sonarr: Set to `info` level in `/mnt/docker/<service>/config.xml`
- SABnzbd: Configured via Web UI (Settings → Logging)
- NZBHydra2: Configured via Web UI (Settings → Logging)

**Do not** add external logrotate configuration - applications manage their own logs and Docker handles container logs.

## Git Workflow

**IMPORTANT: Never commit directly to master.**

All changes must be made in a feature branch:
1. If the user hasn't specified a branch name, suggest a descriptive one (e.g., `fix-portainer-permissions`, `add-new-service`)
2. Create the branch before making any changes
3. Commit changes to the branch
4. Push the branch to remote
5. Offer to create a pull request when changes are complete

Example workflow:
```bash
git checkout -b feature-branch-name
# Make changes...
git add .
git commit -m "descriptive message"
git push -u origin feature-branch-name
# Create PR via gh cli or web interface
```

## Notes

- Pi-hole runs on host port 53 - may conflict with systemd-resolved
- Plex uses LinuxServer.io image (`lscr.io/linuxserver/plex`) with `/dev/dri` for GPU transcoding
- Plex uses `VERSION=public` for auto-updates on container restart
- Home Assistant runs privileged with host network for device access
- Task Scheduler runs scheduled maintenance:
  - Daily at midnight: Docker cleanup (prune images/containers/volumes older than 7 days)
  - Sunday at 3 AM: Plex restart (picks up VERSION=public updates)
