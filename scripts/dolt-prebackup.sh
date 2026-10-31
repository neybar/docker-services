#!/bin/sh
# Consistent Dolt snapshot onto the NAS config volume, at /config/backups.
# James's crontab (user jalance, in the docker group), not root and not restic:
#   mkdir -p "$HOME/.local/state"
#   crontab -e
#     CRON_TZ=America/Denver
#     0 3 * * * /home/jalance/Projects/docker-services/scripts/dolt-prebackup.sh >> "$HOME/.local/state/dolt-prebackup.log" 2>&1
# Overwrites the latest files in place. There is no dated retention.
#
# Exit 0 when dolt is not running so cron does not report a stopped database.
# Any other failure exits non-zero and is in the log.

set -eu

log() {
    echo "[$(date)] dolt-prebackup: $*" >&2
}

running=$(docker inspect -f '{{.State.Running}}' dolt 2>/dev/null || true)
if [ "$running" != true ]; then
    log "dolt is not running; skipping snapshot"
    exit 0
fi

docker exec dolt mkdir -p /config/backups/sql

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
    docker exec dolt mkdir -p "/config/backups/native/$db"
    if ! docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('add','nas','file:///config/backups/native/$db');"; then
        log "dolt_backup add failed for $db (often already configured); syncing"
    fi
    docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('sync','nas');"
    # -d and -fn together are rejected. Databases live under data_dir /config/data.
    docker exec -w "/config/data/$db" dolt dolt dump -f -r sql -fn "/config/backups/sql/$db.sql"
done

grants=$(mktemp)
trap 'rm -f "$grants"' EXIT
{
    echo "-- grants $(date)"
    for host in '192.168.0.%' '100.%'; do
        echo "-- beads@${host}"
        docker exec dolt dolt sql -q "SHOW GRANTS FOR 'beads'@'${host}';" || echo "-- no such user beads@${host}"
    done
    echo "-- mysql.user"
    docker exec dolt dolt sql -r csv -q "SELECT User, Host FROM mysql.user;"
} > "$grants"
docker exec -i dolt tee /config/backups/grants.sql >/dev/null < "$grants"

log "snapshot written to /config/backups (NAS volume dolt_config)"
