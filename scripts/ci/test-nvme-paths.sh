#!/bin/bash
#
# Tests for scripts/lib/nvme-paths.sh. Run by lint.yml; also safe to run by hand (no docker, no network, no root).
#   1. docker-compose.yml's ${NVME_DIR:-...} mounts and the NVME_PATHS table agree (service, path, container mount,
#      default), and compose no longer mounts a legacy path.
#   2. nvme_layout_check (the deploy.sh guard) against fake trees.
#   3. scripts/migrate-nvme-layout.sh (dry run, --apply, second --apply, refusals) against a fake tree under a temp
#      directory, with compose stubbed. Everything it creates is removed on exit.
#
# Usage: ./scripts/ci/test-nvme-paths.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$REPO/scripts/migrate-nvme-layout.sh"
# shellcheck source=../lib/nvme-paths.sh
source "$REPO/scripts/lib/nvme-paths.sh"
pass=0
fail=0

ok() {
    if [[ "$2" == 0 ]]; then
        ((pass++))
    else
        ((fail++))
        echo "FAIL: $1"
        if [[ -n "${3:-}" ]]; then while IFS= read -r line; do echo "  $line"; done <<<"$3"; fi
    fi
}

# --- 1. compose vs table -------------------------------------------------------------------------------------------

# "<service>|<raw mount>" for every non-comment line under services: that mentions ${NVME_DIR
compose_mounts=$(awk '
    /^services:/ { in_s = 1; next }
    /^[^ #]/ { in_s = 0 }
    !in_s || /^[[:space:]]*#/ { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc) }
    # long syntax: "source: ${NVME_DIR...}" then "target: <mount>", printed as "<source>:<target>|<create_host_path>"
    pend != "" && /^[[:space:]]*target:/ { t = $0; sub(/^[[:space:]]*target:[[:space:]]*/, "", t); sub(/[[:space:]]+#.*$/, "", t); pt = t; next }
    pend != "" && /create_host_path:/ { chp = $2 }
    pend != "" && (/^[[:space:]]*- / || /^  [A-Za-z0-9_.-]+:/ || /^    [a-z_]+:/) && !/^[[:space:]]*(target|bind|create_host_path|source|read_only):/ {
        print psvc "|" pend ":" pt "|" chp; pend = ""
    }
    /^[[:space:]]*source:[[:space:]]*\$\{NVME_DIR/ {
        m = $0; sub(/^[[:space:]]*source:[[:space:]]*/, "", m); sub(/[[:space:]]+#.*$/, "", m); gsub(/["\047]/, "", m)
        pend = m; psvc = svc; pt = ""; chp = "true"; next
    }
    index($0, "${NVME_DIR") {
        m = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", m); sub(/[[:space:]]+#.*$/, "", m); gsub(/["\047]/, "", m)
        print svc "|" m "|true"
    }
    END { if (pend != "") print psvc "|" pend ":" pt "|" chp }' "$REPO/docker-compose.yml")

want="" got="" bad_default=""
for row in "${NVME_PATHS[@]}"; do
    IFS='|' read -r svc _ _ _ rel mount <<<"$row"
    want+="$svc|$rel|$mount"$'\n'
done
prefix="\${NVME_DIR:-$NVME_DIR_DEFAULT}/"
declare -A create_host_path=()
while IFS='|' read -r svc m chp; do
    [[ -z "$svc" ]] && continue
    create_host_path["$svc|${m##*:}"]=$chp
    if [[ "$m" != "$prefix"* ]]; then
        bad_default+="$svc: $m"$'\n'
        continue
    fi
    m="${m#"$prefix"}"
    IFS=':' read -r rel mount _ <<<"$m"
    got+="$svc|$rel|$mount"$'\n'
done <<<"$compose_mounts"
want=$(sort <<<"$want" | sed '/^$/d')
got=$(sort <<<"$got" | sed '/^$/d')
ok "compose NVMe mounts match NVME_PATHS" "$([[ "$want" == "$got" ]] && echo 0 || echo 1)" \
    "$(diff <(echo "$want") <(echo "$got") | sed 's/^</table only:/; s/^>/compose only:/' | grep only)"
no_guard=""
for row in "${NVME_PATHS[@]}"; do
    IFS='|' read -r svc _ kind _ _ mount <<<"$row"
    [[ "$kind" == data && "${create_host_path["$svc|$mount"]:-missing}" != false ]] && no_guard+="$svc $mount"$'\n'
done
ok "every data mount sets bind.create_host_path: false" "$([[ -z "$no_guard" ]] && echo 0 || echo 1)" "$no_guard"
ok "every \${NVME_DIR} mount uses the default $NVME_DIR_DEFAULT" "$([[ -z "$bad_default" ]] && echo 0 || echo 1)" "$bad_default"

legacy_hits=""
for row in "${NVME_PATHS[@]}"; do
    IFS='|' read -r _ _ _ legacy _ _ <<<"$row"
    legacy_hits+=$(grep -nE "^[^#]*[[:space:]-]$legacy(:|/)" "$REPO/docker-compose.yml")
done
ok "compose mounts no legacy path" "$([[ -z "$legacy_hits" ]] && echo 0 || echo 1)" "$legacy_hits"

# --- fake trees ----------------------------------------------------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# tree <dir>: a fake host. legacy/ holds the legacy paths (LEGACY_ROOT), nvme/ is NVME_DIR, deploy/ is DEPLOY_DIR.
tree() {
    local t="$1"
    mkdir -p "$t/legacy/usr/local/plex/Library/db" "$t/legacy/usr/local/nzbhydra2/database" \
        "$t/legacy/usr/local/dolt/data/beads" "$t/legacy/tmp/plex_transcode" "$t/nvme" "$t/deploy"
    printf 'library' >"$t/legacy/usr/local/plex/Library/db/plex.db"
    printf 'pref' >"$t/legacy/usr/local/plex/Preferences.xml"
    printf 'h2' >"$t/legacy/usr/local/nzbhydra2/database/nzbhydra.mv.db"
    : >"$t/legacy/usr/local/dolt/data/.init_completed"
    printf 'noms' >"$t/legacy/usr/local/dolt/data/beads/x"
    chmod 750 "$t/legacy/tmp/plex_transcode"
    # shellcheck disable=SC2016 # $(pwd) and $* belong to the stub
    printf '#!/bin/sh\necho "$(pwd)|$*" >>"%s/compose.log"\n' "$t" >"$t/compose"
    chmod +x "$t/compose"
}

# fake <tree> <cmd...>: run with the fake tree's paths.
fake() {
    local t="$1"
    shift
    LEGACY_ROOT="$t/legacy" NVME_DIR="$t/nvme" DEPLOY_DIR="$t/deploy" NVME_COMPOSE="$t/compose" "$@"
}

# Each run sources the library in a fresh bash, so nothing leaks between cases.
# shellcheck disable=SC2016
guard() {
    fake "$1" bash -c 'source "$0"; nvme_layout_check "$1"' "$REPO/scripts/lib/nvme-paths.sh" "$1/deploy"
}

snapshot() {
    (cd "$1" && find . -printf '%p %y %s %m %l\n' | sort)
}

# --- 2. deploy guard -----------------------------------------------------------------------------------------------

t="$TMP/guard-fresh"
mkdir -p "$t/legacy" "$t/nvme" "$t/deploy"
out=$(guard "$t"); ok "guard: fresh host (neither path) passes" $? "$out"

t="$TMP/guard-legacy"
tree "$t"
out=$(guard "$t"); rc=$?
ok "guard: legacy data + missing target refuses" "$((rc == 1 ? 0 : 1))" "$out"
ok "guard: refusal names plex, hydra and dolt and the migrate script" \
    "$(grep -q 'plex config' <<<"$out" && grep -q 'hydra database' <<<"$out" && grep -q 'dolt data' <<<"$out" \
        && grep -q 'migrate-nvme-layout.sh --apply' <<<"$out" && echo 0 || echo 1)" "$out"
ok "guard: scratch row (plex transcode) is never checked" "$(grep -q transcode <<<"$out" && echo 1 || echo 0)" "$out"

mkdir -p "$t/nvme/plex/config" "$t/nvme/nzbhydra2/database" "$t/nvme/dolt/data"
out=$(guard "$t"); rc=$?
ok "guard: legacy data + empty target refuses" "$((rc == 1 ? 0 : 1))" "$out"

t="$TMP/guard-env"
tree "$t"
printf 'NVME_DIR=%s/elsewhere\n' "$t" >"$t/deploy/.env"
out=$(LEGACY_ROOT="$t/legacy" bash -c 'unset NVME_DIR; source "$0"; nvme_layout_check "$1"' \
    "$REPO/scripts/lib/nvme-paths.sh" "$t/deploy")
ok "guard: reads NVME_DIR from the deploy checkout's .env" "$(grep -q "$t/elsewhere/plex/config" <<<"$out" && echo 0 || echo 1)" "$out"

# --- 3. migrate ----------------------------------------------------------------------------------------------------

t="$TMP/migrate"
tree "$t"
before=$(snapshot "$t")
out=$(fake "$t" "$MIGRATE" 2>&1); rc=$?
ok "migrate dry run: exit 0" "$rc" "$out"
ok "migrate dry run: changes nothing, no compose call" "$([[ "$(snapshot "$t")" == "$before" ]] && echo 0 || echo 1)" "$out"
ok "migrate dry run: prints each move" "$(grep -c -- '-> move' <<<"$out" | grep -qx 3 && grep -q -- '-> create empty' <<<"$out" && echo 0 || echo 1)" "$out"

if ((EUID != 0)); then
    out=$(fake "$t" "$MIGRATE" --apply 2>&1); rc=$?
    ok "migrate --apply as non-root refuses, changes nothing" \
        "$([[ $rc != 0 && "$(snapshot "$t")" == "$before" ]] && echo 0 || echo 1)" "$out"
fi

out=$(NVME_MIGRATE_ALLOW_NONROOT=1 fake "$t" "$MIGRATE" --apply 2>&1); rc=$?
ok "migrate --apply: exit 0" "$rc" "$out"
links=0
for p in usr/local/plex usr/local/nzbhydra2/database usr/local/dolt/data; do
    [[ -L "$t/legacy/$p" ]] && links=$((links + 1))
done
ok "migrate --apply: legacy paths are symlinks" "$((links == 3 ? 0 : 1))" "$out"
ok "migrate --apply: data is at the new paths" "$([[ "$(cat "$t/nvme/plex/config/Library/db/plex.db")" == library \
    && -f "$t/nvme/nzbhydra2/database/nzbhydra.mv.db" && -f "$t/nvme/dolt/data/.init_completed" \
    && "$(readlink "$t/legacy/usr/local/plex")" == "$t/nvme/plex/config" ]] && echo 0 || echo 1)" "$out"
ok "migrate --apply: data still reachable through the legacy path" \
    "$([[ "$(cat "$t/legacy/usr/local/plex/Preferences.xml")" == pref ]] && echo 0 || echo 1)"
ok "migrate --apply: transcode created empty with the legacy mode, /tmp one kept" \
    "$([[ "$(stat -c %a "$t/nvme/plex/transcode")" == 750 && -d "$t/legacy/tmp/plex_transcode" && ! -L "$t/legacy/tmp/plex_transcode" ]] && echo 0 || echo 1)"
ok "migrate --apply: stopped then started plex hydra dolt, from DEPLOY_DIR" \
    "$([[ "$(cat "$t/compose.log")" == "$t/deploy|stop plex hydra dolt"$'\n'"$t/deploy|start plex hydra dolt" ]] && echo 0 || echo 1)" \
    "$(cat "$t/compose.log")"
out=$(guard "$t"); ok "guard: migrated host (symlinks) passes" $? "$out"

after=$(snapshot "$t")
out=$(NVME_MIGRATE_ALLOW_NONROOT=1 fake "$t" "$MIGRATE" --apply 2>&1); rc=$?
ok "migrate second --apply: exit 0, 'Already migrated'" "$([[ $rc == 0 ]] && grep -q 'Already migrated' <<<"$out" && echo 0 || echo 1)" "$out"
ok "migrate second --apply: changes nothing, no compose call" "$([[ "$(snapshot "$t")" == "$after" ]] && echo 0 || echo 1)"

t="$TMP/migrate-conflict"
tree "$t"
mkdir -p "$t/nvme/dolt/data" && : >"$t/nvme/dolt/data/stray"
before=$(snapshot "$t")
out=$(NVME_MIGRATE_ALLOW_NONROOT=1 fake "$t" "$MIGRATE" --apply 2>&1); rc=$?
ok "migrate --apply: non-empty target refuses before stopping anything" \
    "$([[ $rc != 0 && "$(snapshot "$t")" == "$before" ]] && grep -q 'REFUSE' <<<"$out" && echo 0 || echo 1)" "$out"
out=$(fake "$t" "$MIGRATE" 2>&1); rc=$?
ok "migrate dry run with a conflict: exit 0, reports REFUSE" "$([[ $rc == 0 ]] && grep -q 'would refuse' <<<"$out" && echo 0 || echo 1)" "$out"

t="$TMP/migrate-empty-target"
tree "$t"
mkdir -p "$t/nvme/plex/config"
out=$(NVME_MIGRATE_ALLOW_NONROOT=1 fake "$t" "$MIGRATE" --apply 2>&1); rc=$?
ok "migrate --apply: empty target directory is renamed over, not moved into" \
    "$([[ $rc == 0 && -f "$t/nvme/plex/config/Preferences.xml" && ! -e "$t/nvme/plex/config/plex" ]] && echo 0 || echo 1)" "$out"

echo "nvme-paths: $pass passed, $fail failed"
((fail == 0))
