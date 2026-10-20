#!/bin/sh
# Traefik access log rotation
# Renames access.log to a timestamped access.log.<YYYYmmdd-HHMMSS>, then sends USR1 so Traefik reopens access.log.
# Only the newest 2 rotated files are kept (timestamp names sort lexically). CrowdSec follows the file by name and picks up the new one.

LOG_DIR="/traefik-logs"
ROTATED="$LOG_DIR/access.log.$(date +%Y%m%d-%H%M%S)"

echo "[$(date)] Rotating Traefik access log..."

if [ ! -f "$LOG_DIR/access.log" ]; then
    echo "[$(date)] ERROR: $LOG_DIR/access.log not found."
    exit 1
fi

mv "$LOG_DIR/access.log" "$ROTATED"

if docker kill -s USR1 traefik; then
    echo "[$(date)] Traefik signalled, log rotation complete ($ROTATED)."
else
    # Traefik never reopened the file, so it is still writing to the renamed inode. Put the name back
    # (unless a new access.log appeared meanwhile) so CrowdSec keeps reading the file Traefik writes.
    echo "[$(date)] ERROR: Failed to signal Traefik (docker kill -s USR1 traefik)."
    if [ ! -e "$LOG_DIR/access.log" ]; then
        mv "$ROTATED" "$LOG_DIR/access.log" \
            && echo "[$(date)] Restored access.log from $ROTATED." \
            || echo "[$(date)] ERROR: Could not restore access.log; Traefik is writing to $ROTATED."
    else
        echo "[$(date)] access.log already exists, leaving $ROTATED in place."
    fi
    exit 1
fi

# Keep the newest 2 rotated files; names are timestamps, so a lexical sort is chronological (no spaces in names)
for old in $(find "$LOG_DIR" -maxdepth 1 -name 'access.log.*' -type f | sort -r | tail -n +3); do
    rm -f -- "$old"
done
