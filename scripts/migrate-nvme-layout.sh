#!/bin/bash
#
# Move the NVMe data of plex, hydra and dolt from their legacy paths to $NVME_DIR/<service>/<role>
# (the table in scripts/lib/nvme-paths.sh). One-time; run it before the deploy that switches compose to the new paths.
#
# Usage: ./scripts/migrate-nvme-layout.sh            dry run: prints each move, size, owner and both ends; changes nothing
#        sudo ./scripts/migrate-nvme-layout.sh --apply
#
# --apply, in order, refusing before it stops anything if a check fails:
#   - must be root; every target must be missing or an empty directory; source and target on the same filesystem
#   - stops the services with data to move (./scripts/compose.sh stop, from DEPLOY_DIR)
#   - per source: counts entries and bytes, mv (a rename), leaves a symlink at the legacy path so the compose file
#     that is deployed now keeps working until the new one is, re-counts and compares (stops on a mismatch, leaving
#     the services stopped)
#   - creates the scratch rows (plex/transcode) empty, with the owner and mode of the legacy directory; nothing moves
#   - starts the services it stopped and prints a summary
# Idempotent: once everything is migrated it reports "already migrated" and does nothing. Never deletes anything.
#
#   DEPLOY_DIR  checkout whose compose project is running (default /home/jalance/Projects/docker-services); its .env
#               may set NVME_DIR
#   NVME_DIR    overrides the target parent (default /usr/local/docker)
# Tests only: LEGACY_ROOT (prefix for the legacy paths), NVME_COMPOSE (compose command),
#             NVME_MIGRATE_ALLOW_NONROOT=1 (skip the root check).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-/home/jalance/Projects/docker-services}"
COMPOSE="${NVME_COMPOSE:-$DEPLOY_DIR/scripts/compose.sh}"

# shellcheck source=lib/nvme-paths.sh
source "$SCRIPT_DIR/lib/nvme-paths.sh"

apply=false
case "${1:-}" in
    "") ;;
    --apply) apply=true ;;
    *) echo "Usage: $0 [--apply]" >&2; exit 2 ;;
esac

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ROOT=$(nvme_dir "$DEPLOY_DIR")

# describe <path>: one line on what is there.
describe() {
    local p="$1" size
    if [[ -L "$p" ]]; then
        echo "symlink -> $(readlink "$p")"
    elif [[ -d "$p" ]]; then
        size=$(du -sh "$p" 2>/dev/null | cut -f1) || size="${size:-?} (partial: some entries unreadable)"
        if nvme_has_entries "$p"; then
            echo "directory, $size, $(stat -c '%U:%G (%u:%g) mode %a' "$p")"
        else
            echo "empty directory, $(stat -c '%U:%G (%u:%g) mode %a' "$p")"
        fi
    elif [[ -e "$p" ]]; then
        echo "not a directory: $(stat -c '%F' "$p")"
    else
        echo "missing"
    fi
}

# device <path>: st_dev of the path, or of its nearest existing ancestor.
device() {
    local p="$1"
    while [[ ! -e "$p" ]]; do p=$(dirname "$p"); done
    stat -c %d "$p"
}

# counts <dir>: "<entries> <bytes>" (every entry below <dir>; apparent bytes of regular files).
counts() {
    local n b
    n=$(find "$1" -mindepth 1 -printf . | wc -c)
    b=$(find "$1" -type f -printf '%s\n' | awk '{s += $1} END {printf "%d", s}')
    echo "$n $b"
}

# state <kind> <src> <dst>: migrated | todo | create | absent | conflict:<reason>
state() {
    local kind="$1" src="$2" dst="$3"
    if [[ "$kind" == scratch ]]; then
        if [[ -d "$dst" && ! -L "$dst" ]]; then
            echo migrated
        elif [[ -e "$dst" || -L "$dst" ]]; then
            echo "conflict:$dst exists and is not a directory"
        else
            echo create
        fi
        return
    fi
    if [[ -L "$src" ]]; then
        if [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" && -d "$dst" ]]; then
            echo migrated
        else
            echo "conflict:$src is a symlink, but not to $dst"
        fi
    elif [[ -d "$src" ]]; then
        if [[ -L "$dst" ]] || { [[ -e "$dst" ]] && [[ ! -d "$dst" ]]; }; then
            echo "conflict:$dst exists and is not a directory"
        elif [[ -d "$dst" ]] && nvme_has_entries "$dst"; then
            echo "conflict:$dst already exists and is not empty"
        elif [[ "$(device "$src")" != "$(device "$dst")" ]]; then
            echo "conflict:$src and $dst are on different filesystems (mv would copy, not rename)"
        else
            echo todo
        fi
    elif [[ -e "$src" ]]; then
        echo "conflict:$src is not a directory"
    else
        echo absent
    fi
}

# Plan every row first; nothing changes until all of them are known to be safe.
rows=() states=() todo=0 create=0 conflicts=0 services=()
for row in "${NVME_PATHS[@]}"; do
    IFS='|' read -r svc role kind legacy rel mount <<<"$row"
    src=$(nvme_legacy "$legacy")
    dst="$ROOT/$rel"
    st=$(state "$kind" "$src" "$dst")
    rows+=("$row")
    states+=("$st")
    case "$st" in
        todo)
            todo=$((todo + 1))
            [[ " ${services[*]} " == *" $svc "* ]] || services+=("$svc")
            ;;
        create) create=$((create + 1)) ;;
        conflict:*) conflicts=$((conflicts + 1)) ;;
    esac
done

echo "NVMe layout: $ROOT/<service>/<role>"
for i in "${!rows[@]}"; do
    IFS='|' read -r svc role kind legacy rel mount <<<"${rows[$i]}"
    src=$(nvme_legacy "$legacy")
    dst="$ROOT/$rel"
    st="${states[$i]}"
    echo
    echo "$svc $role ($kind, mounted at $mount)"
    echo "  legacy: $src"
    echo "          $(describe "$src")"
    echo "  new:    $dst"
    echo "          $(describe "$dst")"
    case "$st" in
        todo) echo "  -> move (rename, same filesystem), then symlink $src -> $dst" ;;
        create) echo "  -> create empty (scratch, nothing moves), owner/mode from $src if it exists" ;;
        migrated) echo "  -> already migrated" ;;
        absent) echo "  -> nothing to move ($src does not exist)" ;;
        conflict:*) echo "  -> REFUSE: ${st#conflict:}" ;;
    esac
done
echo

if ((conflicts > 0)); then
    if [[ "$apply" != true ]]; then
        echo "Dry run: nothing was changed. --apply would refuse: $conflicts path(s) marked REFUSE above."
        exit 0
    fi
    die "$conflicts path(s) cannot be migrated (REFUSE above); nothing was changed"
fi
if ((todo == 0 && create == 0)); then
    echo "Already migrated: nothing to do."
    exit 0
fi
if [[ "$apply" != true ]]; then
    echo "Dry run: nothing was changed. Would stop: ${services[*]:-nothing}. To migrate:"
    echo "  sudo $0 --apply"
    exit 0
fi

if [[ "$EUID" -ne 0 && "${NVME_MIGRATE_ALLOW_NONROOT:-}" != 1 ]]; then
    die "--apply must run as root (sudo $0 --apply)"
fi

compose() {
    (cd "$DEPLOY_DIR" && "$COMPOSE" "$@")
}

on_exit() {
    local rc=$?
    ((rc == 0)) && return
    echo "FAILED (exit $rc). Nothing was deleted. Services stopped by this run stay stopped: ${stopped[*]:-none}." >&2
    echo "Run $0 without --apply to see each path's state." >&2
}
trap on_exit EXIT

summary=() stopped=()
if ((todo > 0)); then
    echo "==> Stopping ${services[*]} (from $DEPLOY_DIR)"
    compose stop "${services[@]}"
    stopped=("${services[@]}")
fi

for i in "${!rows[@]}"; do
    IFS='|' read -r svc role kind legacy rel mount <<<"${rows[$i]}"
    src=$(nvme_legacy "$legacy")
    dst="$ROOT/$rel"
    case "${states[$i]}" in
        todo)
            read -r n_before b_before < <(counts "$src")
            echo "==> $svc $role: $src ($n_before entries, $b_before bytes) -> $dst"
            mkdir -p "$(dirname "$dst")"
            # -T: rename onto the target itself (rename(2) replaces an empty directory), never into it.
            mv -T "$src" "$dst"
            ln -sT "$dst" "$src"
            read -r n_after b_after < <(counts "$dst")
            if [[ "$n_before $b_before" != "$n_after $b_after" ]]; then
                echo "MISMATCH for $svc $role: before $n_before entries / $b_before bytes, after $n_after / $b_after." >&2
                echo "Stopped here: ${services[*]} are left stopped. Nothing was deleted. To put this one back:" >&2
                echo "  rm $src && mv -T $dst $src" >&2
                exit 1
            fi
            summary+=("$svc $role: moved $n_after entries, $b_after bytes to $dst; $src is a symlink to it")
            ;;
        create)
            if [[ -d "$src" ]]; then
                read -r owner mode < <(stat -c '%u:%g %a' "$src")
            else
                # Owner of the same service's config row (plex/config), else root.
                owner=$(stat -c '%u:%g' "$(nvme_target_path "$DEPLOY_DIR" "$svc" config)" 2>/dev/null) || owner=0:0
                mode=755
            fi
            echo "==> $svc $role: creating $dst (owner $owner, mode $mode)"
            mkdir -p "$(dirname "$dst")"
            install -d -o "${owner%:*}" -g "${owner#*:}" -m "$mode" "$dst"
            summary+=("$svc $role: created $dst empty (owner $owner, mode $mode); $src left as is")
            ;;
    esac
done

if ((todo > 0)); then
    echo "==> Starting ${services[*]}"
    compose start "${services[@]}"
    stopped=()
fi

echo
echo "Summary:"
for s in "${summary[@]}"; do echo "  $s"; done
echo "The compose file deployed now still uses the legacy paths, through the symlinks. Once the PR with the"
echo "\$NVME_DIR mounts is deployed, the symlinks are unused; they can be removed by hand after that."
