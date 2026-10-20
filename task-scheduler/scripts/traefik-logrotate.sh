#!/bin/sh
# Traefik access log rotation (copytruncate)
# Copies access.log to a timestamped access.log.<YYYYmmdd-HHMMSS>, then truncates access.log in place.
# Traefik opens the file with O_APPEND (v3.6 openAccessLogFile), so after the truncate it keeps writing at the new
# end of the same inode: no signal, no Docker API access, no window where access.log is missing. CrowdSec follows
# the same inode and sees the truncation. Lines written between the copy and the truncate are not in the archive
# (they are still read by CrowdSec as they were written); the archive is history only.
# Only the newest 2 rotated files are kept (timestamp names sort lexically).

LOG_DIR="/traefik-logs"
LOG="$LOG_DIR/access.log"
ROTATED="$LOG.$(date +%Y%m%d-%H%M%S)"

echo "[$(date)] Rotating Traefik access log..."

if [ ! -f "$LOG" ]; then
    echo "[$(date)] ERROR: $LOG not found."
    exit 1
fi

# Never truncate unless the copy succeeded: the archive is the only record of what is about to be cleared.
if ! cp -p "$LOG" "$ROTATED"; then
    echo "[$(date)] ERROR: Failed to copy $LOG to $ROTATED; access.log left untouched."
    rm -f -- "$ROTATED"
    exit 1
fi

if ! : > "$LOG"; then
    echo "[$(date)] ERROR: Failed to truncate $LOG; $ROTATED is a duplicate of it."
    exit 1
fi

echo "[$(date)] Log rotation complete ($ROTATED)."

# Keep the newest 2 rotated files; names are timestamps, so a lexical sort is chronological (no spaces in names)
for old in $(find "$LOG_DIR" -maxdepth 1 -name 'access.log.*' -type f | sort -r | tail -n +3); do
    rm -f -- "$old"
done
