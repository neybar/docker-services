#!/bin/bash
#
# Traefik v3 Migration Validation Script
# Validates all services are accessible and properly configured after migration
#
# Usage: ./scripts/validate-traefik.sh [domain]
# If domain is not provided, reads from .env file
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load domain from .env if not provided as argument
if [[ $# -ge 1 ]]; then
    DOMAIN="$1"
elif [[ -f "$PROJECT_DIR/.env" ]]; then
    DOMAIN=$(grep -E "^DOMAINNAME=" "$PROJECT_DIR/.env" | cut -d'=' -f2)
else
    echo -e "${RED}Error: No domain provided and .env file not found${NC}"
    echo "Usage: $0 [domain]"
    exit 1
fi

if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}Error: DOMAINNAME not set${NC}"
    exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Traefik v3 Validation Script${NC}"
echo -e "${BLUE}  Domain: ${DOMAIN}${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Service definitions: name:subdomain (subdomain defaults to name if not specified)
SERVICES=(
    "traefik"
    "authelia"
    "plex"
    "portainer"
    "start"        # Organizr
    "sonarr"
    "radarr"
    "bazarr"
    "sabnzb"
    "hydra"
    "books"        # Calibre-Web
    "lazylib"
    "homeassistant"
    "pihole"
    "smokeping"
    "homebridge"
    "home"         # DSM (Synology)
)

# Function to print test result
print_result() {
    local test_name="$1"
    local status="$2"
    local message="${3:-}"

    if [[ "$status" == "PASS" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} $test_name"
        ((PASSED++))
    elif [[ "$status" == "FAIL" ]]; then
        echo -e "  ${RED}[FAIL]${NC} $test_name"
        [[ -n "$message" ]] && echo -e "         ${RED}$message${NC}"
        ((FAILED++))
    elif [[ "$status" == "WARN" ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} $test_name"
        [[ -n "$message" ]] && echo -e "         ${YELLOW}$message${NC}"
        ((WARNINGS++))
    fi
}

# Function to test HTTP status code
test_http_status() {
    local url="$1"
    local expected="${2:-200}"
    local timeout="${3:-10}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" -k "$url" 2>/dev/null) || status="000"

    if [[ "$status" == "$expected" ]]; then
        return 0
    else
        echo "$status"
        return 1
    fi
}

# Function to check response header
check_header() {
    local url="$1"
    local header="$2"
    local timeout="${3:-10}"

    local headers
    headers=$(curl -s -I --max-time "$timeout" -k "$url" 2>/dev/null)

    if echo "$headers" | grep -qi "^$header:"; then
        return 0
    else
        return 1
    fi
}

# Function to get header value
get_header() {
    local url="$1"
    local header="$2"
    local timeout="${3:-10}"

    curl -s -I --max-time "$timeout" -k "$url" 2>/dev/null | grep -i "^$header:" | cut -d':' -f2- | tr -d '\r' | xargs
}

echo -e "${BLUE}1. Testing Service Accessibility (HTTP 200)${NC}"
echo "   Testing ${#SERVICES[@]} services..."
echo ""

for service in "${SERVICES[@]}"; do
    url="https://${service}.${DOMAIN}"

    if result=$(test_http_status "$url" "200" 15); then
        print_result "$service ($url)" "PASS"
    else
        # Check if we got a redirect (302, 303, 307, 308) which may be OK
        if [[ "$result" =~ ^30[2378]$ ]]; then
            print_result "$service ($url)" "WARN" "Got redirect ($result) - may need authentication"
        else
            print_result "$service ($url)" "FAIL" "HTTP $result"
        fi
    fi
done

echo ""
echo -e "${BLUE}2. Testing HTTP to HTTPS Redirect${NC}"
echo ""

# Test HTTP redirect (should get 308 Permanent Redirect)
http_url="http://${SERVICES[0]}.${DOMAIN}"
redirect_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$http_url" 2>/dev/null) || redirect_status="000"

if [[ "$redirect_status" == "308" ]]; then
    print_result "HTTP->HTTPS redirect (308 Permanent)" "PASS"
elif [[ "$redirect_status" =~ ^30[127]$ ]]; then
    print_result "HTTP->HTTPS redirect" "PASS" "Got $redirect_status (acceptable redirect)"
elif [[ "$redirect_status" == "000" ]]; then
    print_result "HTTP->HTTPS redirect" "WARN" "Connection failed - port 80 may be blocked or service down"
else
    print_result "HTTP->HTTPS redirect" "FAIL" "Expected 308, got $redirect_status"
fi

echo ""
echo -e "${BLUE}3. Testing Security Headers${NC}"
echo ""

# Test Permissions-Policy header (formerly Feature-Policy)
test_url="https://traefik.${DOMAIN}"

if check_header "$test_url" "Permissions-Policy"; then
    policy=$(get_header "$test_url" "Permissions-Policy")
    print_result "Permissions-Policy header present" "PASS"
    echo -e "         Value: $policy"
else
    # Check for old Feature-Policy (indicates v2 still running)
    if check_header "$test_url" "Feature-Policy"; then
        print_result "Permissions-Policy header" "FAIL" "Found Feature-Policy instead (Traefik v2 still running?)"
    else
        print_result "Permissions-Policy header" "FAIL" "Header not found"
    fi
fi

# Test other security headers
if check_header "$test_url" "Strict-Transport-Security"; then
    print_result "Strict-Transport-Security (HSTS)" "PASS"
else
    print_result "Strict-Transport-Security (HSTS)" "WARN" "Header not found"
fi

if check_header "$test_url" "X-Content-Type-Options"; then
    print_result "X-Content-Type-Options" "PASS"
else
    print_result "X-Content-Type-Options" "WARN" "Header not found"
fi

if check_header "$test_url" "X-Frame-Options"; then
    print_result "X-Frame-Options" "PASS"
else
    print_result "X-Frame-Options" "WARN" "Header not found"
fi

echo ""
echo -e "${BLUE}4. Testing TLS Certificate${NC}"
echo ""

# Check certificate validity
cert_info=$(echo | openssl s_client -servername "traefik.${DOMAIN}" -connect "traefik.${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

if [[ -n "$cert_info" ]]; then
    not_after=$(echo "$cert_info" | grep "notAfter" | cut -d'=' -f2)

    # Check if cert is currently valid
    now=$(date +%s)
    cert_end=$(date -d "$not_after" +%s 2>/dev/null || echo "0")

    if [[ $cert_end -gt $now ]]; then
        days_remaining=$(( (cert_end - now) / 86400 ))
        print_result "TLS certificate valid" "PASS"
        echo -e "         Expires: $not_after ($days_remaining days remaining)"
    else
        print_result "TLS certificate valid" "FAIL" "Certificate expired on $not_after"
    fi

    # Check if it's a wildcard cert
    cert_subject=$(echo | openssl s_client -servername "traefik.${DOMAIN}" -connect "traefik.${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
    if echo "$cert_subject" | grep -q "\*\.${DOMAIN}"; then
        print_result "Wildcard certificate (*.${DOMAIN})" "PASS"
    fi
else
    print_result "TLS certificate" "FAIL" "Could not retrieve certificate"
fi

echo ""
echo -e "${BLUE}5. Testing Traefik Dashboard${NC}"
echo ""

dashboard_url="https://traefik.${DOMAIN}/dashboard/"
if result=$(test_http_status "$dashboard_url" "200" 15); then
    print_result "Traefik dashboard accessible" "PASS"
else
    if [[ "$result" =~ ^30[2378]$ ]]; then
        print_result "Traefik dashboard" "WARN" "Redirect to auth ($result) - expected behavior"
    else
        print_result "Traefik dashboard" "FAIL" "HTTP $result"
    fi
fi

# Check API endpoint
api_url="https://traefik.${DOMAIN}/api/version"
if result=$(test_http_status "$api_url" "200" 10); then
    version=$(curl -s -k "$api_url" 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$version" ]]; then
        print_result "Traefik API responding" "PASS"
        echo -e "         Version: $version"

        # Check if v3
        if [[ "$version" =~ ^3\. ]]; then
            print_result "Running Traefik v3" "PASS"
        else
            print_result "Running Traefik v3" "FAIL" "Got version $version"
        fi
    else
        print_result "Traefik API responding" "PASS"
    fi
else
    if [[ "$result" =~ ^30[2378]$ ]]; then
        print_result "Traefik API" "WARN" "Redirect to auth ($result)"
    else
        print_result "Traefik API" "FAIL" "HTTP $result"
    fi
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "  ${GREEN}Passed:${NC}   $PASSED"
echo -e "  ${RED}Failed:${NC}   $FAILED"
echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All critical tests passed!${NC}"
    exit 0
elif [[ $FAILED -le 2 ]]; then
    echo -e "${YELLOW}Some tests failed. Review warnings and failures above.${NC}"
    exit 1
else
    echo -e "${RED}Multiple failures detected. Consider rollback if issues persist.${NC}"
    exit 2
fi
