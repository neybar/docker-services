#!/bin/bash
#
# Look up this host's LAN and Tailscale addresses, for the validate scripts only: they are test targets (local
# resolution past public DNS, and Dolt's TLS check on each address). Compose does not use them: no service binds a
# host address, so plain `docker compose` needs none of this. Source it, do not run it.
#
#   host_ip       source address of the IPv4 default route in the *main* routing table (orcrist: enp2s0f0, the LAN).
#                 Not `ip route get <internet ip>`: with a Tailscale exit node in use, Tailscale's policy rule
#                 (table 52) routes that via tailscale0 and would return the Tailscale address. If the route has no
#                 `src`, the first global IPv4 address on the route's interface. Exactly one default route is
#                 required: with two (wired + Wi-Fi, a VPN) picking one would be a guess.
#   tailscale_ip  `tailscale ip -4`; must be in 100.64.0.0/10.
#
# Each prints the address, or prints why to stderr and returns 1.

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
