#!/bin/bash
#
# Dolt (Beads) Validation Script
# Validates the Dolt sql-server: healthy, TLS-only with a certificate that verifies for dolt.<domain>
# on both published addresses, beads can log in, remote root cannot, and init did not rerun.
#
# Usage: ./scripts/validate-dolt.sh [domain]
# If domain is not provided, reads from .env file
#
# Notes:
#   - Run on this host. The MySQL client is the pinned image MYSQL_IMAGE, run with
#     `docker run --rm --network host` (pulled on first use); nothing is installed on the host.
#   - dolt.<domain> is mapped to each address in the client container (--add-host), so the
#     certificate is verified against that name on HOST_IP and on TAILSCALE_IP. Never skip-verify.
#   - The beads password is read from .env and given to the client as an option file on stdin:
#     never printed, never on a command line.
#   - Read-only queries; creates nothing, so there is nothing to clean up.
#

set -uo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/validate-common.sh
source "$SCRIPT_DIR/lib/validate-common.sh"

load_env "$@"
print_banner "Dolt (Beads) Validation Script"

MYSQL_IMAGE="mysql:8.4.6"
DOLT_PORT=3307
DOLT_HOST="dolt.${DOMAIN}"
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

cd "$PROJECT_DIR" || exit 1

TAILSCALE_IP=$(grep -E '^TAILSCALE_IP=' .env 2>/dev/null | cut -d'=' -f2)
BEADS_PASSWORD=$(grep -E '^DOLT_BEADS_PASSWORD=' .env 2>/dev/null | cut -d'=' -f2-)

# mysql_query <ip> <ssl-mode> <user> <password, may be empty> <sql>
# Prints the client's stdout+stderr; exit status is the client's.
mysql_query() {
    local ip="$1" mode="$2" user="$3" password="$4" sql="$5"
    {
        printf '[client]\nuser=%s\n' "$user"
        if [[ -n "$password" ]]; then
            printf 'password=%s\n' "$password"
        fi
    } | docker run --rm -i --network host \
        --add-host "${DOLT_HOST}:${ip}" \
        -v "${CA_BUNDLE}:/ca.crt:ro" \
        --entrypoint mysql "$MYSQL_IMAGE" \
        --defaults-extra-file=/dev/stdin \
        --host="$DOLT_HOST" --port="$DOLT_PORT" \
        --ssl-mode="$mode" --ssl-ca=/ca.crt \
        --connect-timeout=10 --batch --skip-column-names \
        -e "$sql" 2>&1
}

# First line of client output that looks like an error, for FAIL messages
first_error() {
    grep -m1 -iE 'error|denied|insecure' <<<"$1" || head -n1 <<<"$1"
}

echo -e "${BLUE}1. Testing Container${NC}"
echo ""

health=$(docker compose ps --format '{{.Health}}' dolt 2>/dev/null)
state=$(docker compose ps --format '{{.State}}' dolt 2>/dev/null)
if [[ "$state" == "running" && "$health" == "healthy" ]]; then
    print_result "dolt running and healthy" "PASS"
else
    print_result "dolt running and healthy" "FAIL" "state='${state:-none}' health='${health:-none}'"
fi

for tool in docker openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_result "$tool available" "FAIL" "$tool is not installed"
    fi
done
if [[ ! -r "$CA_BUNDLE" ]]; then
    print_result "CA bundle readable" "FAIL" "$CA_BUNDLE not readable (Ubuntu ca-certificates)"
fi

echo ""
echo -e "${BLUE}2. Testing Init${NC}"
echo ""

if docker compose exec -T dolt test -f /var/lib/dolt/.init_completed 2>/dev/null; then
    print_result "/var/lib/dolt/.init_completed exists" "PASS"
else
    print_result "/var/lib/dolt/.init_completed exists" "FAIL" "Missing: the next start reruns init (wrong data mount?)"
fi

# The image logs "running|sourcing /docker-entrypoint-initdb.d/<file>" (or "No files found in ...") only when init runs
container_id=$(docker compose ps -q dolt 2>/dev/null)
started=""
[[ -n "$container_id" ]] && started=$(docker inspect -f '{{.State.StartedAt}}' "$container_id" 2>/dev/null)
if [[ -z "$started" ]]; then
    print_result "Init did not run on this boot" "FAIL" "No dolt container"
elif docker compose logs --no-log-prefix --since "$started" dolt 2>&1 | grep -q '/docker-entrypoint-initdb.d/'; then
    print_result "Init did not run on this boot" "FAIL" "Init ran: expected only on the first start of an empty /usr/local/dolt/data"
else
    print_result "Init did not run on this boot" "PASS"
fi

# 3./4. Same checks on each published address
section=3
for target in "LAN:${HOST_IP:-}" "Tailscale:${TAILSCALE_IP}"; do
    label=${target%%:*}
    ip=${target#*:}

    echo ""
    echo -e "${BLUE}${section}. Testing ${label} (${ip:-unset}:${DOLT_PORT})${NC}"
    echo ""
    section=$((section + 1))

    if [[ -z "$ip" ]]; then
        print_result "${label} address set in .env" "FAIL" "Set HOST_IP and TAILSCALE_IP in .env"
        continue
    fi

    # Chain and hostname verification against the system CA bundle
    tls_out=$(timeout 15 openssl s_client -starttls mysql -connect "${ip}:${DOLT_PORT}" \
        -servername "$DOLT_HOST" -verify_hostname "$DOLT_HOST" -verify_return_error \
        -CAfile "$CA_BUNDLE" </dev/null 2>&1)
    tls_rc=$?
    if [[ $tls_rc -eq 0 ]] && grep -q 'Verify return code: 0 (ok)' <<<"$tls_out"; then
        print_result "TLS certificate verifies for ${DOLT_HOST}" "PASS"
        expiry=$(openssl x509 -noout -enddate <<<"$tls_out" 2>/dev/null | cut -d'=' -f2)
        [[ -n "$expiry" ]] && echo -e "         Expires: ${expiry}"
    else
        print_result "TLS certificate verifies for ${DOLT_HOST}" "FAIL" \
            "$(grep -m1 -iE 'verify (error|return code)|error|refused' <<<"$tls_out" || echo "openssl exit $tls_rc")"
    fi

    # Non-existent user and no password: nothing secret is sent in the clear
    out=$(mysql_query "$ip" DISABLED validate-dolt-plaintext "" "SELECT 1;")
    rc=$?
    if [[ $rc -ne 0 ]] && grep -qi 'insecure' <<<"$out"; then
        print_result "Plaintext connection rejected" "PASS"
    elif [[ $rc -eq 0 ]]; then
        print_result "Plaintext connection rejected" "FAIL" "A plaintext login succeeded"
    else
        print_result "Plaintext connection rejected" "FAIL" "Unexpected error: $(first_error "$out")"
    fi

    if [[ -z "$BEADS_PASSWORD" ]]; then
        print_result "beads logs in over verified TLS" "FAIL" "DOLT_BEADS_PASSWORD missing or empty in .env"
    else
        out=$(mysql_query "$ip" VERIFY_IDENTITY beads "$BEADS_PASSWORD" "SELECT CURRENT_USER(), @@secure_file_priv;")
        rc=$?
        current_user=$(cut -f1 <<<"$out")
        file_priv=$(cut -f2 <<<"$out")
        if [[ $rc -eq 0 && "$current_user" == beads@* ]]; then
            print_result "beads logs in over verified TLS" "PASS"
            echo -e "         As: ${current_user}"
            if [[ "$file_priv" == "/secure-priv" ]]; then
                print_result "secure_file_priv is /secure-priv" "PASS"
            else
                print_result "secure_file_priv is /secure-priv" "FAIL" "Got '${file_priv}': LOAD_FILE can read the password secret"
            fi
        else
            print_result "beads logs in over verified TLS" "FAIL" "$(first_error "$out")"
        fi
    fi

    out=$(mysql_query "$ip" VERIFY_IDENTITY root "" "SELECT 1;")
    rc=$?
    if [[ $rc -ne 0 ]] && grep -qi 'access denied' <<<"$out"; then
        print_result "Remote root rejected" "PASS"
    elif [[ $rc -eq 0 ]]; then
        print_result "Remote root rejected" "FAIL" "root logged in from ${ip}: check mysql.user for root@'%'"
    else
        print_result "Remote root rejected" "FAIL" "Unexpected error: $(first_error "$out")"
    fi
done

print_summary

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All Dolt checks passed!${NC}"
    exit 0
else
    echo -e "${RED}Dolt checks failed. Review failures above.${NC}"
    exit 1
fi
