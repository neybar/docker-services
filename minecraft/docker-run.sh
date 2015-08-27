#!/bin/sh
docker run -it -p 25565:25565 -e EULA=true -v /home/jalance/games/minecraft_spigot:/minecraft --name minecraft nimmis/spigot
