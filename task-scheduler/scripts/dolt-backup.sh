#!/bin/sh
# Nightly Dolt backup. Writes on local disk first, then copies to /mnt/backups/dolt
# (Grond) only when that path is a cifs or smb3 mount. Dated SQL dumps are kept
# (14 days) so a delete is not only mirrored away. The native dolt_backup sync IS a mirror.
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

# Field 3 is the filesystem type. Any bind mount matches a mountpoint check,
# including an empty directory Docker created while the host CIFS share is down.
grond_fstype=$(awk '$2 == "/mnt/backups/dolt" { print $3; exit }' /proc/mounts)
case $grond_fstype in
    cifs | smb3)
        mkdir -p "$REMOTE/native" "$REMOTE/sql"
        # --delete mirrors branch deletions and must not run against a local dir.
        if [ "$grond_fstype" = cifs ] || [ "$grond_fstype" = smb3 ]; then
            rsync -a --delete "$LOCAL/native/" "$REMOTE/native/"
        fi
        rsync -a "$LOCAL/sql/" "$REMOTE/sql/"
        rotate "$REMOTE/sql"
        echo "[$(date)] Copied backups to $REMOTE ($grond_fstype)"
        ;;
    *)
        echo "[$(date)] WARNING: $REMOTE is not cifs or smb3 (type: ${grond_fstype:-not mounted}); local backup kept, Grond copy skipped."
        ;;
esac

echo "[$(date)] Dolt backup complete."
