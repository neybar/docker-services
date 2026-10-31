#!/bin/sh
# Config lives on the NFS volume mounted at /config (copied from this repo at setup).
# The image entrypoint only looks in /etc/dolt/servercfg.d and /docker-entrypoint-initdb.d,
# so those paths are symlinks. Data is the nested bind /config/data (/usr/local/dolt/data).
# A missing file exits. The image defaults would otherwise start without this config.

set -eu

fail=0
for f in \
    /config/servercfg/config.yaml \
    /config/init/01-beads-user.sh \
    /config/certs/certificate.crt \
    /config/certs/privatekey.key
do
    if [ ! -s "$f" ]; then
        echo "dolt: required file missing or empty: $f" >&2
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "dolt: refusing to start. Copy dolt/servercfg, dolt/init, and dolt/entrypoint.sh to /mnt/docker/dolt. Certs are written to certs/ by dolt-certs.sh. Starting without these files would use image defaults." >&2
    exit 1
fi

mkdir -p /etc/dolt
rm -rf /etc/dolt/servercfg.d
ln -s /config/servercfg /etc/dolt/servercfg.d
rm -rf /docker-entrypoint-initdb.d
ln -s /config/init /docker-entrypoint-initdb.d

exec tini -- docker-entrypoint.sh "$@"
