#!/bin/bash
#
# CrowdSec WAF Validation Script
# Validates the CrowdSec + Traefik bouncer/AppSec setup is healthy and enforcing
#
# Usage: ./scripts/validate-waf.sh [domain]
# If domain is not provided, reads from .env file
#
# Notes:
#   - Run from this host: LAN sources are whitelisted from bans, but NOT from AppSec blocking.
#   - The /.env probe is a harmless GET; it is blocked by AppSec and creates an alert, not a ban.
#   - Creates no decisions or files, so there is nothing to clean up.
#

set -uo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/validate-common.sh
source "$SCRIPT_DIR/lib/validate-common.sh"

load_env "$@"
print_banner "CrowdSec WAF Validation Script"

# Maximum age (seconds) of the bouncer's last LAPI pull (stream interval is 60s)
MAX_PULL_AGE=300

# Test pages (Organizr, LAN bypasses Authelia)
TEST_HOST="start.${DOMAIN}"

cd "$PROJECT_DIR" || exit 1

# Function to get HTTP status code for a path on TEST_HOST
http_status() {
    local path="$1" code
    if [[ -n "${HOST_IP:-}" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -k \
            --resolve "${TEST_HOST}:443:${HOST_IP}" "https://${TEST_HOST}${path}" 2>/dev/null) || true
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -k "https://${TEST_HOST}${path}" 2>/dev/null) || true
    fi
    echo "${code:-000}"
}

echo -e "${BLUE}1. Testing Containers${NC}"
echo ""

for svc in crowdsec traefik; do
    health=$(docker compose ps --format '{{.Health}}' "$svc" 2>/dev/null)
    state=$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null)
    if [[ "$state" == "running" && "$health" == "healthy" ]]; then
        print_result "$svc running and healthy" "PASS"
    else
        print_result "$svc running and healthy" "FAIL" "state='${state:-none}' health='${health:-none}'"
    fi
done

echo ""
echo -e "${BLUE}2. Testing CrowdSec${NC}"
echo ""

# An empty key fails closed (plugin rejects it, crowdsec@file is never built); never print the key
if grep -Eq '^CROWDSEC_BOUNCER_KEY=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
    print_result "CROWDSEC_BOUNCER_KEY set in .env" "PASS"
else
    print_result "CROWDSEC_BOUNCER_KEY set in .env" "FAIL" "Missing or empty; an empty key breaks every chained router (see REBUILD.md, CrowdSec)"
fi

if docker compose exec -T crowdsec cscli lapi status >/dev/null 2>&1; then
    print_result "LAPI reachable (cscli lapi status)" "PASS"
else
    print_result "LAPI reachable (cscli lapi status)" "FAIL" "cscli lapi status failed"
fi

# Bouncer is named "traefik" (registered from the bouncer_key_traefik secret) or "traefik@<ip>" (auto-registered); use the most recent pull among them
if ! command -v jq >/dev/null 2>&1; then
    last_pull=""
    bouncer_err="jq is not installed, cannot read the bouncer list (install jq)"
else
    last_pull=$(docker compose exec -T crowdsec cscli bouncers list -o json 2>/dev/null \
        | jq -r '[.[] | select(.name == "traefik" or (.name | startswith("traefik@"))) | .last_pull // empty] | sort | last // empty' 2>/dev/null)
    bouncer_err="No 'traefik' or 'traefik@*' bouncer, or it has never pulled"
fi
if [[ -z "$last_pull" ]]; then
    print_result "Traefik bouncer registered and pulling" "FAIL" "$bouncer_err"
else
    pull_epoch=$(date -d "$last_pull" +%s 2>/dev/null || echo "0")
    pull_age=$(( $(date +%s) - pull_epoch ))
    if [[ $pull_age -le $MAX_PULL_AGE ]]; then
        print_result "Traefik bouncer registered and pulling" "PASS"
        echo -e "         Last pull: ${pull_age}s ago"
    else
        print_result "Traefik bouncer registered and pulling" "FAIL" "Last pull ${pull_age}s ago (max ${MAX_PULL_AGE}s)"
    fi
fi

# AppSec listener (inside the crowdsec container)
if docker compose exec -T crowdsec bash -c 'exec 3<>/dev/tcp/127.0.0.1/7422' >/dev/null 2>&1; then
    print_result "AppSec listening on :7422" "PASS"
else
    print_result "AppSec listening on :7422" "FAIL" "Nothing listening on 127.0.0.1:7422 in the crowdsec container"
fi

echo ""
echo -e "${BLUE}3. Testing WAF Enforcement${NC}"
echo ""

# A normal page must pass through the bouncer
status=$(http_status "/")
if [[ "$status" =~ ^[23] ]]; then
    print_result "Normal page allowed (https://${TEST_HOST}/)" "PASS" "HTTP $status"
else
    print_result "Normal page allowed (https://${TEST_HOST}/)" "FAIL" "HTTP $status"
fi

# AppSec virtual patching must block the .env probe
status=$(http_status "/.env")
if [[ "$status" == "403" ]]; then
    print_result "/.env probe blocked by AppSec (https://${TEST_HOST}/.env)" "PASS" "HTTP $status"
else
    print_result "/.env probe blocked by AppSec (https://${TEST_HOST}/.env)" "FAIL" "Expected 403, got HTTP $status"
fi

print_summary

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All WAF checks passed!${NC}"
    exit 0
else
    echo -e "${RED}WAF checks failed. Review failures above.${NC}"
    exit 1
fi
