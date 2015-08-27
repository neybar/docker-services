#!/bin/sh
printf "Deleting old backups..."
date +%D
cd /home/jalance/games/minecraft_spigot/backup
ls -tr thelances-*.tar.gz | head -n -5 | xargs --no-run-if-empty rm -v
