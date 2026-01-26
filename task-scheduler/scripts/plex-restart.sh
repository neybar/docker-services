#!/bin/sh
# Plex restart script
# Restarts Plex to pick up updates when using VERSION=public

echo "[$(date)] Restarting Plex container..."

if docker restart plex; then
    echo "[$(date)] Plex container restarted successfully."
else
    echo "[$(date)] ERROR: Failed to restart Plex container."
    exit 1
fi
