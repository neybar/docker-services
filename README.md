# Home Server setup

I've done a whole bunch of stuff with my server setup before writing this.  I'm probably missing steps. Bummer.

Here are a few guides and docs that proved invaluable:
* [https://www.smarthomebeginner.com/traefik-2-docker-tutorial/](https://www.smarthomebeginner.com/traefik-2-docker-tutorial/)
* [https://doc.traefik.io/traefik/](https://doc.traefik.io/traefik/) 
* [https://docs.docker.com/compose/compose-file](https://docs.docker.com/compose/compose-file)

## What's working

So far this is the list of things that I'm serving:
* Traefik + LetsEncrypt + Cloudflare for reverse proxy with SSL
* Authelia for 2FA auth (only for external network access)
* Portainer for giggles.  I haven't actually used it directly yet.
* Organizr
* Medusa
* Calibre-Web
* Lazy Librarian
* PiHole

## TODO

* Plex (currently hosted on Synology)
* SabNZB (also on Synology)
* [https://ombi.io/](https://ombi.io/)
* OwnCloud / NextCloud / etc
* HomeBridge for HomeKit
* Unifi Controller (currently hosted on Synology)
* Radarr
* Lidarr
* Watchtower
* Garbage Collection

## Maybe

* Firefox
* Guacamole
* VSCode

## Setup

* `cp env.example .env`
* Update the values in `.env`.  I'm using cloudflare for DNS.  See [https://www.smarthomebeginner.com/traefik-2-docker-tutorial/#4_Proper_DNS_Records](https://www.smarthomebeginner.com/traefik-2-docker-tutorial/#4_Proper_DNS_Records)
* I have two config directories.  Things that aren't as finicky go on a NFS mount (to my synology).  Something just don't play nice with being on a network mount.  So I have another directory for those configs.  Ergo $DOCKERDIR and $LOCALDOCKERDIR.
* Also I have my synology SMB mounted with the following attributes: `//$IP/audiobooks /mnt/audiobooks cifs user,vers=3.0,uid=$USER,gid=$GROUP,rw,suid,nobrl,file_mode=0600,dir_mode=0700,credentials=/etc/cifspwd 0 0`.  Replace `$IP,$USER,$GROUP` with the correct values.
* Create networks:   
```
# docker network create t2_proxy
# docker network create socket_proxy
# Alternatively, you can specify the gateway and subnet to use
docker network create --gateway 192.168.90.1 --subnet 192.168.90.0/24 t2_proxy
# docker network create --gateway 192.168.91.1 --subnet 192.168.91.0/24 socket_proxy
# Subnet range 192.168.0.0/16 covers 192.168.0.0 to 192.168.255.255
```

### Traefik specific

* touch the `traefik.log` file
* `chmod 600 traefik.log`

### Authelia

* [https://www.smarthomebeginner.com/docker-authelia-tutorial/](https://www.smarthomebeginner.com/docker-authelia-tutorial/)

### pihole

* `touch pihole/pihole.log`
