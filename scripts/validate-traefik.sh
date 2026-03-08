#!/bin/bash
#
# Traefik v3 Migration Validation Script
# Validates all services are accessible and properly configured after migration
#
# Usage: ./scripts/validate-traefik.sh [domain]
# If domain is not provided, reads from .env file
#

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load domain and host IP from .env if not provided as argument
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

# Load HOST_IP for local resolution (bypasses public DNS, enables Authelia local bypass)
if [[ -f "$PROJECT_DIR/.env" ]]; then
    HOST_IP=$(grep -E "^HOST_IP=" "$PROJECT_DIR/.env" | cut -d'=' -f2)
fi

if [[ -z "${HOST_IP:-}" ]]; then
    echo -e "${YELLOW}Warning: HOST_IP not set, using public DNS (may trigger Authelia auth)${NC}"
else
    echo -e "${GREEN}Using local resolution: ${HOST_IP}${NC}"
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

# Service definitions: "subdomain" or "subdomain:/path" for custom test paths
SERVICES=(
    "traefik"
    "authelia"
    "plex"
    "portainer"
    "start"              # Organizr
    "sonarr"
    "radarr"
    "bazarr"
    "sabnzb"
    "hydra"
    "books"              # Calibre-Web
    "calibre"            # Calibre (Local only)
    "lazylib"
    "homeassistant"
    "pihole:/admin/"     # Pi-hole blocks root, test admin path
    "smokeping"
    "speedtest"          # LibreSpeed
    "homebridge"
    "home"               # DSM (Synology)
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
    local host="$2"
    local expected="${3:-200}"
    local timeout="${4:-10}"

    local status
    if [[ -n "${HOST_IP:-}" ]]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" -k \
            --resolve "${host}:443:${HOST_IP}" "$url" 2>/dev/null) || status="000"
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" -k "$url" 2>/dev/null) || status="000"
    fi

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
    local host="$3"
    local timeout="${4:-10}"

    local headers
    if [[ -n "${HOST_IP:-}" ]]; then
        headers=$(curl -s -I --max-time "$timeout" -k --resolve "${host}:443:${HOST_IP}" "$url" 2>/dev/null)
    else
        headers=$(curl -s -I --max-time "$timeout" -k "$url" 2>/dev/null)
    fi

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
    local host="$3"
    local timeout="${4:-10}"

    if [[ -n "${HOST_IP:-}" ]]; then
        curl -s -I --max-time "$timeout" -k --resolve "${host}:443:${HOST_IP}" "$url" 2>/dev/null | grep -i "^$header:" | cut -d':' -f2- | tr -d '\r' | xargs
    else
        curl -s -I --max-time "$timeout" -k "$url" 2>/dev/null | grep -i "^$header:" | cut -d':' -f2- | tr -d '\r' | xargs
    fi
}

echo -e "${BLUE}1. Testing Service Accessibility${NC}"
echo "   Testing ${#SERVICES[@]} services..."
echo ""

for service_def in "${SERVICES[@]}"; do
    # Parse service definition: "subdomain" or "subdomain:/path"
    if [[ "$service_def" == *":"* ]]; then
        service="${service_def%%:*}"
        path="${service_def#*:}"
    else
        service="$service_def"
        path=""
    fi

    url="https://${service}.${DOMAIN}${path}"
    host="${service}.${DOMAIN}"

    # Get HTTP status code (use local resolution if HOST_IP is set)
    if [[ -n "${HOST_IP:-}" ]]; then
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -k \
            --resolve "${host}:443:${HOST_IP}" "$url" 2>/dev/null) || status="000"
    else
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 -k "$url" 2>/dev/null) || status="000"
    fi

    # 2xx, 3xx = success; 401 = service reachable (has own auth); 4xx/5xx = failure
    if [[ "$status" =~ ^[23] ]]; then
        print_result "$service ($url)" "PASS" "HTTP $status"
    elif [[ "$status" == "401" ]]; then
        print_result "$service ($url)" "PASS" "HTTP $status (service has own auth)"
    elif [[ "$status" == "000" ]]; then
        print_result "$service ($url)" "FAIL" "Connection failed"
    else
        print_result "$service ($url)" "FAIL" "HTTP $status"
    fi
done

echo ""
echo -e "${BLUE}2. Testing HTTP to HTTPS Redirect${NC}"
echo ""

# Test HTTP redirect (should get 308 Permanent Redirect)
http_url="http://${SERVICES[0]}.${DOMAIN}"
redirect_host="${SERVICES[0]}.${DOMAIN}"
if [[ -n "${HOST_IP:-}" ]]; then
    redirect_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        --resolve "${redirect_host}:80:${HOST_IP}" "$http_url" 2>/dev/null) || redirect_status="000"
else
    redirect_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$http_url" 2>/dev/null) || redirect_status="000"
fi

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
test_host="traefik.${DOMAIN}"

if check_header "$test_url" "Permissions-Policy" "$test_host"; then
    policy=$(get_header "$test_url" "Permissions-Policy" "$test_host")
    print_result "Permissions-Policy header present" "PASS"
    echo -e "         Value: $policy"
else
    # Check for old Feature-Policy (indicates v2 still running)
    if check_header "$test_url" "Feature-Policy" "$test_host"; then
        print_result "Permissions-Policy header" "FAIL" "Found Feature-Policy instead (Traefik v2 still running?)"
    else
        print_result "Permissions-Policy header" "FAIL" "Header not found"
    fi
fi

# Test other security headers
if check_header "$test_url" "Strict-Transport-Security" "$test_host"; then
    print_result "Strict-Transport-Security (HSTS)" "PASS"
else
    print_result "Strict-Transport-Security (HSTS)" "WARN" "Header not found"
fi

if check_header "$test_url" "X-Content-Type-Options" "$test_host"; then
    print_result "X-Content-Type-Options" "PASS"
else
    print_result "X-Content-Type-Options" "WARN" "Header not found"
fi

if check_header "$test_url" "X-Frame-Options" "$test_host"; then
    print_result "X-Frame-Options" "PASS"
else
    print_result "X-Frame-Options" "WARN" "Header not found"
fi

echo ""
echo -e "${BLUE}4. Testing TLS Certificate${NC}"
echo ""

# Check certificate validity
cert_connect="${HOST_IP:-traefik.${DOMAIN}}:443"
cert_info=$(echo | openssl s_client -servername "traefik.${DOMAIN}" -connect "$cert_connect" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

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
    cert_subject=$(echo | openssl s_client -servername "traefik.${DOMAIN}" -connect "$cert_connect" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
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
dashboard_host="traefik.${DOMAIN}"
if result=$(test_http_status "$dashboard_url" "$dashboard_host" "200" 15); then
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
api_host="traefik.${DOMAIN}"
if result=$(test_http_status "$api_url" "$api_host" "200" 10); then
    if [[ -n "${HOST_IP:-}" ]]; then
        version=$(curl -s -k --resolve "${api_host}:443:${HOST_IP}" "$api_url" 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4)
    else
        version=$(curl -s -k "$api_url" 2>/dev/null | grep -o '"Version":"[^"]*"' | cut -d'"' -f4)
    fi
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
