#!/bin/bash
#
# Derive HOST_IP and TAILSCALE_IP from this host for docker compose. Source it, do not run it.
# They are not in .env: they belong to the host, not the config, and a stored copy goes stale silently.
# Every compose run uses this: scripts/compose.sh (by hand), deploy.sh, scripts/ci/integration-run.sh, the validate
# scripts (via validate-common.sh) and the dolt-* scripts. Compose requires both (`${HOST_IP:?}`), so a compose command
# run without them fails before it does anything.
#
#   HOST_IP       source address of the IPv4 default route in the *main* routing table (orcrist: enp2s0f0, the LAN).
#                 Not `ip route get <internet ip>`: with a Tailscale exit node in use, Tailscale's policy rule
#                 (table 52) routes that via tailscale0 and would return the Tailscale address. If the route has no
#                 `src`, the first global IPv4 address on the route's interface. Exactly one default route is
#                 required: with two (wired + Wi-Fi, a VPN) picking one would be a guess.
#   TAILSCALE_IP  `tailscale ip -4`; must be in 100.64.0.0/10. Optional: only Dolt uses it. If it cannot be derived
#                 (tailscaled down, not logged in, CLI missing) it is set to 127.0.0.1 with a warning, so compose and
#                 deploys still run and Dolt publishes on the LAN (and loopback) only. TAILSCALE_UP=1/0 says which.
#                 The next deploy after tailscaled is back recreates dolt with the real address.
#
# Usage: host_addrs_export [project_dir]
#   Exports HOST_IP, TAILSCALE_IP and TAILSCALE_UP, or prints why to stderr and returns 1 (only when HOST_IP cannot
#   be derived). Never falls back to 0.0.0.0.
#   With project_dir, warns if its .env still sets either variable (the exported value overrides it in compose).

_host_addrs_is_ipv4() {
    local octets o
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -ra octets <<<"$1"
    for o in "${octets[@]}"; do
        ((10#$o <= 255)) || return 1
    done
}

# Prints the LAN address. Usage: host_ip
host_ip() {
    local routes dev src
    if ! routes=$(ip -4 route show default table main); then
        echo "ERROR: HOST_IP: 'ip -4 route show default table main' failed" >&2
        return 1
    fi
    if [[ $(grep -c . <<<"$routes") -ne 1 ]]; then
        echo "ERROR: HOST_IP: need exactly one IPv4 default route in the main table, found: ${routes:-none}" >&2
        return 1
    fi
    dev=$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<<"$routes")
    src=$(awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' <<<"$routes")
    if [[ -z "$src" && -n "$dev" ]]; then
        src=$(ip -4 -o addr show dev "$dev" scope global | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')
    fi
    if ! _host_addrs_is_ipv4 "$src"; then
        echo "ERROR: HOST_IP: no IPv4 address for the default route '$routes'" >&2
        return 1
    fi
    echo "$src"
}

# Prints the Tailscale IPv4 address. Usage: tailscale_ip
tailscale_ip() {
    local ip
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "ERROR: TAILSCALE_IP: the tailscale CLI is not installed" >&2
        return 1
    fi
    if ! ip=$(tailscale ip -4); then
        echo "ERROR: TAILSCALE_IP: 'tailscale ip -4' failed (is tailscaled up?)" >&2
        return 1
    fi
    if ! _host_addrs_is_ipv4 "$ip" || [[ ! "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
        echo "ERROR: TAILSCALE_IP: 'tailscale ip -4' returned '$ip', not one address in 100.64.0.0/10" >&2
        return 1
    fi
    echo "$ip"
}

host_addrs_export() {
    local env_dir="${1:-}" host ts
    host=$(host_ip) || return 1
    TAILSCALE_UP=1
    if ! ts=$(tailscale_ip); then
        echo "WARNING: Tailscale unavailable: Dolt will publish on the LAN ($host) and 127.0.0.1 only, not the tailnet." >&2
        echo "WARNING: everything else is unaffected. Once tailscaled is back, re-run the deploy to restore tailnet access." >&2
        ts=127.0.0.1 TAILSCALE_UP=0
    fi
    if [[ "$host" == "$ts" ]]; then
        echo "ERROR: HOST_IP and TAILSCALE_IP are both $host" >&2
        return 1
    fi
    if [[ -n "$env_dir" && -f "$env_dir/.env" ]] && grep -qE '^(HOST_IP|TAILSCALE_IP)=' "$env_dir/.env"; then
        echo "WARNING: $env_dir/.env still sets HOST_IP/TAILSCALE_IP; ignored, derived from the host. Remove those lines." >&2
    fi
    export HOST_IP="$host" TAILSCALE_IP="$ts" TAILSCALE_UP
}
