#!/bin/sh
# Consistent Dolt snapshot for the host restic job.
# Run as root on orcrist, from /usr/local/sbin/restic-backup, before `restic backup`.
# Uses the host Docker socket (`docker exec`), not the socket proxy.
#
# Exit 0 when dolt is not running so a stopped database does not fail restic.
# Any other failure exits non-zero. The caller should log that and continue:
# a Dolt error must not skip the rest of the host backup. See dolt/RESTORE.md.

set -eu

script_dir=$(dirname "$0")
REPO=$(cd "$script_dir/.." && pwd)
LOCALDOCKERDIR=""
if [ -f "$REPO/.env" ]; then
    LOCALDOCKERDIR=$(grep -E '^LOCALDOCKERDIR=' "$REPO/.env" | head -n 1 | cut -d= -f2-)
    LOCALDOCKERDIR=$(printf '%s' "$LOCALDOCKERDIR" | tr -d '"' | tr -d "'")
fi
if [ -z "$LOCALDOCKERDIR" ]; then
    LOCALDOCKERDIR=/home/jalance/Projects/docker-services
fi

SNAP="$LOCALDOCKERDIR/dolt/backups"

log() {
    echo "[$(date)] dolt-prebackup: $*" >&2
}

running=$(docker inspect -f '{{.State.Running}}' dolt 2>/dev/null || true)
if [ "$running" != true ]; then
    log "dolt is not running; skipping snapshot"
    exit 0
fi

mkdir -p "$SNAP/native" "$SNAP/sql"

dbs=$(docker exec dolt dolt sql -r csv -q "SHOW DATABASES;" | awk -F, 'NR > 1 { gsub(/"/, "", $1); print $1 }')

# Database names here have no spaces; the case below rejects anything else.
# shellcheck disable=SC2086
for db in $dbs; do
    case $db in
        "" | mysql | information_schema | sys | performance_schema) continue ;;
    esac
    case $db in
        *[!A-Za-z0-9_-]*)
            log "skipping database with unexpected name: $db"
            continue
            ;;
    esac

    log "snapshot $db"
    mkdir -p "$SNAP/native/$db"
    if ! docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('add','restic','file:///backups/native/$db');"; then
        log "dolt_backup add failed for $db (often already configured); syncing"
    fi
    docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('sync','restic');"
    # -d and -fn together are rejected. Overwrite the latest dump; restic keeps history.
    docker exec -w "/var/lib/dolt/$db" dolt dolt dump -f -r sql -fn "/backups/sql/$db.sql"
done

{
    echo "-- grants $(date)"
    for host in '192.168.0.%' '100.%'; do
        echo "-- beads@${host}"
        docker exec dolt dolt sql -q "SHOW GRANTS FOR 'beads'@'${host}';" || echo "-- no such user beads@${host}"
    done
    echo "-- mysql.user"
    docker exec dolt dolt sql -r csv -q "SELECT User, Host FROM mysql.user;"
} > "$SNAP/grants.sql"

log "snapshot written to $SNAP"
