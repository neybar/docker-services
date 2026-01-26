#!/bin/sh
# Docker cleanup script using native Docker prune commands

echo "[$(date)] Starting Docker cleanup..."

# Remove unused containers older than 7 days (604800 seconds)
echo "Pruning containers..."
docker container prune -f --filter "until=168h"

# Remove unused images older than 7 days
echo "Pruning images..."
docker image prune -a -f --filter "until=168h"

# Remove unused volumes
echo "Pruning volumes..."
docker volume prune -f

# Remove unused networks
echo "Pruning networks..."
docker network prune -f

# Show disk usage after cleanup
echo "Docker disk usage after cleanup:"
docker system df

echo "[$(date)] Docker cleanup complete."
