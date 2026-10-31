#!/bin/bash
#
# The services that need orcrist's local NVMe, in one table. Source it, do not run it.
# Used by deploy.sh (nvme_layout_check), scripts/migrate-nvme-layout.sh, validate-dolt.sh and
# scripts/ci/test-nvme-paths.sh, which fails if docker-compose.yml's NVMe mounts disagree with this table.
#
# Layout: $NVME_DIR/<service>/<role>. NVME_DIR defaults to /usr/local/docker (on /, the NVMe). It is NOT
# LOCALDOCKERDIR, which is the repo checkout on the /home SATA SSD. A new service that needs the fast drive gets a
# row here and a `${NVME_DIR:-/usr/local/docker}/<service>/<role>:<mount>` bind mount in compose.
#
# Columns (|-separated):
#   compose service | role | kind | legacy path | path relative to NVME_DIR | container mount
#   kind: data    = state that must survive (moved by the migrate script, checked by deploy.sh)
#         scratch = regenerable (created empty by the migrate script, never checked)
# The legacy paths are where the data lived before the $NVME_DIR layout; only the migrate script and the deploy
# guard use them.
NVME_DIR_DEFAULT=/usr/local/docker
NVME_PATHS=(
    "plex|config|data|/usr/local/plex|plex/config|/config"
    "plex|transcode|scratch|/tmp/plex_transcode|plex/transcode|/transcode"
    "hydra|database|data|/usr/local/nzbhydra2/database|nzbhydra2/database|/config/database"
    "dolt|data|data|/usr/local/dolt/data|dolt/data|/var/lib/dolt"
)

# nvme_dir <project_dir>: NVME_DIR as compose resolves it: the environment, else NVME_DIR= in <project_dir>/.env,
# else the default. Only that one line of .env is read.
nvme_dir() {
    local project="$1" v
    if [[ -n "${NVME_DIR:-}" ]]; then
        v="$NVME_DIR"
    elif [[ -f "$project/.env" ]] && v=$(grep -E '^NVME_DIR=' "$project/.env" | tail -1) && [[ -n "$v" ]]; then
        v="${v#NVME_DIR=}"
        v="${v%\"}" && v="${v#\"}"
        v="${v%\'}" && v="${v#\'}"
    fi
    echo "${v:-$NVME_DIR_DEFAULT}"
}

# nvme_legacy <legacy path>: the legacy path, under LEGACY_ROOT if set. LEGACY_ROOT is for tests only (a fake tree).
nvme_legacy() {
    echo "${LEGACY_ROOT:-}$1"
}

# nvme_target_path <project_dir> <compose service> <role>: absolute path of one row under NVME_DIR.
nvme_target_path() {
    local root row svc role rel
    root=$(nvme_dir "$1")
    for row in "${NVME_PATHS[@]}"; do
        IFS='|' read -r svc role _ _ rel _ <<<"$row"
        if [[ "$svc" == "$2" && "$role" == "$3" ]]; then
            echo "$root/$rel"
            return 0
        fi
    done
    return 1
}

# nvme_has_entries <dir>: true if <dir> holds anything, or cannot be listed (unreadable counts as holding data).
nvme_has_entries() {
    local first
    [[ -r "$1" && -x "$1" ]] || return 0
    first=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
    [[ -n "$first" ]]
}

# nvme_layout_check <project_dir>: called by deploy.sh before any container is touched.
# Fails for a data row whose legacy path is still a real, non-empty directory (not the migrate script's symlink)
# while its $NVME_DIR path is missing or empty: compose would create the new path empty and the service would start
# fresh (Plex with an empty library). A fresh host (neither exists) and a migrated host (legacy is a symlink) pass.
# Prints each problem and what to run to stdout; returns 1 if there is any.
nvme_layout_check() {
    local root row svc role kind legacy rel src dst bad=0
    root=$(nvme_dir "$1")
    for row in "${NVME_PATHS[@]}"; do
        IFS='|' read -r svc role kind legacy rel _ <<<"$row"
        [[ "$kind" == data ]] || continue
        src=$(nvme_legacy "$legacy")
        dst="$root/$rel"
        [[ -d "$src" && ! -L "$src" ]] || continue
        nvme_has_entries "$src" || continue
        if [[ ! -e "$dst" ]]; then
            echo "  $svc $role: $dst is missing, but $src still holds the data"
            bad=1
        elif [[ -d "$dst" ]] && ! nvme_has_entries "$dst"; then
            echo "  $svc $role: $dst is empty, but $src still holds the data"
            bad=1
        fi
    done
    ((bad == 0)) && return 0
    echo "  Compose would start these services on an empty $root path. Move the data first (stops and restarts"
    echo "  plex, hydra and dolt; dry run without --apply):"
    echo "    sudo ./scripts/migrate-nvme-layout.sh --apply"
    return 1
}
