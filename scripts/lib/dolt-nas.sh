#!/bin/bash
#
# Compare Dolt's live config on the NAS with the repo templates in dolt/. Source it, do not run it.
# The live copies are copied by hand (the repo is public, see dolt/README.md), so a merged template change
# does not deploy and the two drift silently. deploy.sh refuses to deploy on drift; validate-dolt.sh fails on it.
# Read-only: it never writes to the NAS.
#
# Usage: dolt_nas_drift <project_dir>
#   DOLT_NAS_DIR  host path of the dolt_config volume (default /mnt/docker/dolt)
#   Returns 0 if every live copy matches its template. Otherwise prints each mismatch and the commands to fix it
#   to stdout and returns 1.

# Template (relative to the repo) = live copy (relative to DOLT_NAS_DIR). certs/ and backups/ are written by scripts.
DOLT_NAS_FILES=(servercfg/config.yaml init/01-beads-user.sh)

dolt_nas_drift() {
    local repo="$1" nas="${DOLT_NAS_DIR:-/mnt/docker/dolt}" f live tmpl drifted=() restart=false
    for f in "${DOLT_NAS_FILES[@]}"; do
        tmpl="$repo/dolt/$f"
        live="$nas/$f"
        if [[ ! -r "$live" ]]; then
            echo "  $live is missing or unreadable (template dolt/$f)"
            drifted+=("$f")
        elif ! cmp -s "$tmpl" "$live"; then
            echo "  $live differs from dolt/$f"
            drifted+=("$f")
        else
            continue
        fi
        [[ "$f" == servercfg/* ]] && restart=true
    done
    ((${#drifted[@]} == 0)) && return 0

    echo "  Review, then copy the templates to the NAS (from the checkout root):"
    for f in "${drifted[@]}"; do
        echo "    diff -u $nas/$f dolt/$f"
        echo "    cp dolt/$f $nas/$f"
    done
    if [[ "$restart" == true ]]; then
        echo "  Dolt reads its config only at start: ./scripts/compose.sh restart dolt"
    else
        echo "  The init script runs only on a first start; no restart needed."
    fi
    return 1
}
