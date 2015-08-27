#!/bin/sh
printf "Starting backup..."
date +%D
cd /home/jalance/games/minecraft_spigot
tmux send -t minecraft /save-off ENTER
tar -czvf backup/thelances-`date +%m%d%y_%H_%M_%S`.tar.gz thelances.net
tmux send -t minecraft /save-on ENTER
