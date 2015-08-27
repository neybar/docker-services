#!/bin/sh
/usr/bin/tmux new-session -s minecraft -d
/usr/bin/tmux send -t minecraft "docker start -i minecraft" ENTER
