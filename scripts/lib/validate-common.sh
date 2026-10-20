#!/bin/bash
#
# Shared helpers for scripts/validate-*.sh. Source it, do not run it.
#
# Caller contract: set PROJECT_DIR before calling load_env, then call load_env "$@" (sets DOMAIN, HOST_IP),
# print_banner "<title>", and finish with print_summary. Provides colors, the PASSED/FAILED/WARNINGS
# counters, print_result and the curl_resolved/curl_status helpers. The caller keeps its own `set -uo pipefail`.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Load domain and host IP from .env if not provided as argument. Usage: load_env "$@"
# Exits on error, so it must run in the caller's shell (not a subshell).
load_env() {
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
}

# curl against <host>:<port>, pointing the connection at HOST_IP when set (local resolution) and ignoring TLS
# verification. Usage: curl_resolved <host> <port> <url> [extra curl args...]. Prints curl's output; exit status is curl's.
curl_resolved() {
    local host="$1" port="$2" url="$3"
    shift 3
    local resolve=()
    [[ -n "${HOST_IP:-}" ]] && resolve=(--resolve "${host}:${port}:${HOST_IP}")
    curl -s -k "${resolve[@]}" "$@" "$url" 2>/dev/null
}

# HTTP status code of https://<host><path>, 000 on failure. Usage: curl_status <host> <path> [extra curl args...]
curl_status() {
    local host="$1" path="$2" code
    shift 2
    code=$(curl_resolved "$host" 443 "https://${host}${path}" -o /dev/null -w "%{http_code}" "$@") || true
    echo "${code:-000}"
}

# Banner with the script title and the resolved domain
print_banner() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}  Domain: ${DOMAIN}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

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

# Summary block with the counters; the caller prints its own verdict and picks the exit code
print_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo ""
}
