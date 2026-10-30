#!/bin/sh
# Dump the Let's Encrypt wildcard out of Traefik's acme.json and, if the PEM
# changed, restart dolt so it loads the new files. Dolt reads TLS material only
# at startup. One cert pair is installed at the paths in dolt/servercfg/config.yaml.

set -eu

SRC=/acme/acme.json
DEST=/dolt-certs
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[$(date)] Refreshing Dolt TLS material from acme.json"

if [ ! -s "$SRC" ]; then
    echo "[$(date)] ERROR: $SRC is missing or empty." >&2
    exit 1
fi

mkdir -p "$DEST"

traefik-certs-dumper file --version v3 --source "$SRC" --dest "$STAGE" --domain-subdir

pick=""
if [ -n "${DOMAINNAME:-}" ] && [ -f "$STAGE/$DOMAINNAME/certificate.crt" ] && [ -f "$STAGE/$DOMAINNAME/privatekey.key" ]; then
    pick="$STAGE/$DOMAINNAME"
else
    # shellcheck disable=SC2086
    set -- "$STAGE"/*/certificate.crt
    if [ -f "$1" ] && [ ! -e "${2:-}" ]; then
        pick=$(dirname "$1")
    fi
fi

if [ -z "$pick" ] || [ ! -s "$pick/certificate.crt" ] || [ ! -s "$pick/privatekey.key" ]; then
    echo "[$(date)] ERROR: no single certificate.crt under $STAGE (set DOMAINNAME to choose)." >&2
    find "$STAGE" -type f -print >&2
    exit 1
fi

changed=0
if [ ! -f "$DEST/certificate.crt" ] || ! cmp -s "$pick/certificate.crt" "$DEST/certificate.crt"; then
    changed=1
fi
if [ ! -f "$DEST/privatekey.key" ] || ! cmp -s "$pick/privatekey.key" "$DEST/privatekey.key"; then
    changed=1
fi

if [ "$changed" -eq 0 ]; then
    echo "[$(date)] Certificate unchanged; dolt not restarted."
    exit 0
fi

cp "$pick/certificate.crt" "$DEST/certificate.crt.tmp"
cp "$pick/privatekey.key" "$DEST/privatekey.key.tmp"
chmod 644 "$DEST/certificate.crt.tmp"
chmod 600 "$DEST/privatekey.key.tmp"
mv "$DEST/certificate.crt.tmp" "$DEST/certificate.crt"
mv "$DEST/privatekey.key.tmp" "$DEST/privatekey.key"

echo "[$(date)] Certificate updated from $(basename "$pick")."
# POST /containers/dolt/restart. CONTAINERS=1 matches /containers/*, and POST=1 allows the method. EXEC is not used.
if docker restart dolt; then
    echo "[$(date)] dolt restarted to load the new certificate."
else
    echo "[$(date)] ERROR: certificate installed but docker restart dolt failed." >&2
    exit 1
fi
