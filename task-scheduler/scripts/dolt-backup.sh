#!/bin/sh
# Nightly Dolt backup. Writes on local disk first, then copies to /mnt/backups/dolt
# (Grond) when that path is a mount. Dated SQL dumps are kept (14 days) so a
# delete is not only mirrored away. The native dolt_backup sync IS a mirror.
#
# bd export (JSONL) is not run here: bd is not installed in this image. See dolt/RESTORE.md.

set -eu

STAMP=$(date +%Y%m%d)
LOCAL=/dolt-backups
REMOTE=/mnt/backups/dolt
KEEP=14

echo "[$(date)] Starting Dolt backup"

mkdir -p "$LOCAL/native" "$LOCAL/sql/$STAMP"
docker exec dolt mkdir -p "/backups/sql/$STAMP" "/backups/native"

dbs=$(docker exec dolt dolt sql -r csv -q "SHOW DATABASES;" | awk -F, 'NR > 1 { gsub(/"/, "", $1); print $1 }')

for db in $dbs; do
    case $db in
        mysql | information_schema | sys | performance_schema) continue ;;
    esac
    case $db in
        *[!A-Za-z0-9_-]*)
            echo "[$(date)] skipping database with unexpected name: $db"
            continue
            ;;
    esac

    echo "[$(date)] backing up $db"
    docker exec dolt mkdir -p "/backups/native/$db"
    if ! docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('add','nightly','file:///backups/native/$db');"; then
        echo "[$(date)] dolt_backup add failed for $db (often: already configured); syncing anyway"
    fi
    docker exec dolt dolt sql -q "USE \`$db\`; CALL dolt_backup('sync','nightly');"
    # -d and -fn together are rejected ("cannot pass both directory and file names").
    docker exec -w "/var/lib/dolt/$db" dolt dolt dump -f -r sql -fn "/backups/sql/$STAMP/$db.sql"
done

{
    echo "-- grants $(date -Iseconds 2>/dev/null || date)"
    for host in '192.168.0.%' '100.%'; do
        echo "-- beads@${host}"
        docker exec dolt dolt sql -q "SHOW GRANTS FOR 'beads'@'${host}';" || echo "-- no such user beads@${host}"
    done
    echo "-- mysql.user"
    docker exec dolt dolt sql -r csv -q "SELECT User, Host FROM mysql.user;"
} > "$LOCAL/sql/$STAMP/grants.sql"

rotate() {
    dir=$1
    for old in $(find "$dir" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9][0-9][0-9][0-9][0-9]' | sort -r | tail -n +"$((KEEP + 1))"); do
        rm -rf -- "$old"
    done
}

rotate "$LOCAL/sql"

if grep -q ' /mnt/backups/dolt ' /proc/mounts; then
    mkdir -p "$REMOTE/native" "$REMOTE/sql"
    rsync -a --delete "$LOCAL/native/" "$REMOTE/native/"
    rsync -a "$LOCAL/sql/" "$REMOTE/sql/"
    rotate "$REMOTE/sql"
    echo "[$(date)] Copied backups to $REMOTE"
else
    echo "[$(date)] WARNING: $REMOTE is not a mount; local backup kept, Grond copy skipped."
fi

echo "[$(date)] Dolt backup complete."
