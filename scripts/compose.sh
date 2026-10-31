#!/bin/bash
#
# `docker compose` for this stack, with HOST_IP and TAILSCALE_IP derived from the host (scripts/lib/host-addrs.sh).
# They are not in .env, and compose refuses every command without them, so use this for compose commands by hand:
#   ./scripts/compose.sh ps
#   ./scripts/compose.sh restart traefik
# Arguments go to `docker compose` unchanged, run from the current directory (the checkout root, as before).

set -euo pipefail

# shellcheck source=lib/host-addrs.sh
source "$(dirname "$(readlink -f "$0")")/lib/host-addrs.sh"
host_addrs_export "$PWD" || exit 1

exec docker compose "$@"
