#!/bin/sh
# Create the beads login from the compose secret. No GRANT on *.*.
#
# Dolt 2.6.1 does not apply database-name wildcards (a mysql.db row of db='%'
# or db='db%' did not permit DML on a new database). GRANT ... ON *.* does,
# and it also lets the user UPDATE mysql.user: tested, that changed root's
# host from localhost to '%' and a remote root login then succeeded. Root has
# no password by default. So this script only creates the account. Per-project
# grants are applied by scripts/dolt-add-db.sh.
#
# Template: the live copy is init/ on the NAS volume dolt_config, mounted at
# /docker-entrypoint-initdb.d. Runs once, from the image entrypoint, when
# /var/lib/dolt/.init_completed is absent. To pick up a new secret without wiping data:
#   docker compose exec -T dolt /docker-entrypoint-initdb.d/01-beads-user.sh
# Password must be a single hex token (openssl rand -hex 32): it is interpolated
# into SQL, so quotes, backslashes, and whitespace are rejected.

set -eu

secret=/run/secrets/dolt_beads_password
if [ ! -r "$secret" ]; then
    echo "beads user: $secret is not readable" >&2
    exit 1
fi

password=$(tr -d '\r\n' < "$secret")
if [ -z "$password" ]; then
    echo "beads user: empty password" >&2
    exit 1
fi
case $password in
    *\'* | *\\* | *[[:space:]]*)
        echo "beads user: password must be one token without quotes or backslashes (openssl rand -hex 32)" >&2
        exit 1
        ;;
esac

# 192.168.0.% is the LAN. 100.% approximates Tailscale CGNAT (100.64.0.0/10);
# MySQL host patterns cannot express a /10. Host matching itself works
# (a user@'192.168.0.%' was denied from 172.17.0.0/16).
for host in '192.168.0.%' '100.%'; do
    dolt sql -q "CREATE USER IF NOT EXISTS 'beads'@'${host}' IDENTIFIED BY '${password}'; ALTER USER 'beads'@'${host}' IDENTIFIED BY '${password}';"
done

dolt sql -q "SELECT User, Host FROM mysql.user WHERE User = 'beads';"
