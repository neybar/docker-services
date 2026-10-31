#!/bin/bash
# Consistent Dolt snapshot onto the NAS volume dolt_config (backups/, mounted at /backups;
# /mnt/docker/dolt/backups on the host). Overwrites the latest files in place; no dated retention.
# Runs from jalance's crontab, not task-scheduler: it needs `docker exec`, and socket-proxy has
# EXEC off on purpose (it would let every socket-proxy client exec into every container).
# The crontab line is in REBUILD.md §1.
#
# Exit 0 when dolt is not running so cron does not report a stopped database.
# Any other failure exits non-zero and is in the log.

set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "$0")")")"

log() {
    echo "[$(date)] dolt-prebackup: $*" >&2
}

# Compose needs HOST_IP and TAILSCALE_IP, derived from the host (not in .env)
# shellcheck source=lib/host-addrs.sh
source scripts/lib/host-addrs.sh
host_addrs_export "$PWD" || { log "cannot derive HOST_IP/TAILSCALE_IP"; exit 1; }

dolt_exec() {
    docker compose exec -T "$@"
}

if [[ -z "$(docker compose ps --status running -q dolt 2>/dev/null)" ]]; then
    log "dolt is not running; skipping snapshot"
    exit 0
fi

dolt_exec dolt mkdir -p /backups/sql

dbs=$(dolt_exec dolt dolt sql -r csv -q "SHOW DATABASES;" | awk -F, 'NR > 1 { gsub(/"/, "", $1); print $1 }')

for db in $dbs; do
    case $db in
        "" | mysql | information_schema | sys | performance_schema) continue ;;
    esac
    if ! [[ "$db" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log "skipping database with unexpected name: $db"
        continue
    fi

    log "snapshot $db"
    dolt_exec dolt mkdir -p "/backups/native/$db"
    if ! dolt_exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('add','nas','file:///backups/native/$db');"; then
        log "dolt_backup add failed for $db (often already configured); syncing"
    fi
    dolt_exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('sync','nas');"
    # -d and -fn together are rejected, so run from the database directory under data_dir.
    dolt_exec -w "/var/lib/dolt/$db" dolt dolt dump -f -r sql -fn "/backups/sql/$db.sql"
done

# Collected first, so a failed query does not truncate the previous grants.sql.
grants=$(mktemp)
trap 'rm -f "$grants"' EXIT
{
    echo "-- grants $(date)"
    for host in '192.168.0.%' '100.%'; do
        echo "-- beads@${host}"
        dolt_exec dolt dolt sql -q "SHOW GRANTS FOR 'beads'@'${host}';" || echo "-- no such user beads@${host}"
    done
    echo "-- mysql.user"
    dolt_exec dolt dolt sql -r csv -q "SELECT User, Host FROM mysql.user;"
} > "$grants"
dolt_exec dolt tee /backups/grants.sql >/dev/null < "$grants"

log "snapshot written to /backups (NAS volume dolt_config)"
