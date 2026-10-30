#!/bin/sh
# Certs are dumped by task-scheduler. Wait for them, then run the image entrypoint.
# Dolt will not start (and will not serve plaintext) until both PEMs are in place.

i=0
while [ ! -s /certs/certificate.crt ] || [ ! -s /certs/privatekey.key ]; do
    i=$((i + 1))
    if [ "$i" -eq 1 ] || [ $((i % 15)) -eq 0 ]; then
        echo "dolt: waiting for /certs/certificate.crt and /certs/privatekey.key"
    fi
    sleep 2
done

exec tini -- docker-entrypoint.sh "$@"
