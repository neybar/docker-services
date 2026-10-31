#!/bin/bash
# Create one Beads project database and grant `beads` on that database only.
# Run on orcrist from this repo, after the dolt container is up:
#   ./scripts/dolt-add-db.sh <prefix>
# The SQL runs as root inside the container. Root is localhost-only; this does
# not open a remote root login.
#
# bd init --server --external creates the database itself when it is missing
# (CreateIfMissing is set on that path in beads v1.3.2). This script pre-creates
# it so beads does not need a global CREATE grant. Whether `bd init --external`
# then finishes against that pre-created database was not run here (no bd binary).

set -euo pipefail

cd "$(dirname "$(dirname "$(readlink -f "$0")")")"

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <prefix>" >&2
    exit 1
fi

name=$1
if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,63}$ ]]; then
    echo "invalid database name: $name" >&2
    echo "use a letter or underscore, then letters, digits, underscore, or hyphen (max 64)" >&2
    exit 1
fi
case $name in
    mysql | information_schema | sys | performance_schema)
        echo "refusing system database name: $name" >&2
        exit 1
        ;;
esac

# CREATE/DROP/ALTER/INDEX are for bd's schema and migrations.
# EXECUTE covers DOLT_ADD, DOLT_COMMIT, and DOLT_CHECKOUT on this database.
# No GRANT OPTION, FILE, CREATE USER, or *.* .
sql="CREATE DATABASE IF NOT EXISTS \`$name\`;"
for host in '192.168.0.%' '100.%'; do
    sql="${sql} GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, EXECUTE ON \`$name\`.* TO 'beads'@'${host}';"
done

# Compose needs HOST_IP and TAILSCALE_IP, derived from the host (not in .env)
# shellcheck source=lib/host-addrs.sh
source scripts/lib/host-addrs.sh
host_addrs_export "$PWD" || exit 1

docker compose exec -T dolt dolt sql -q "$sql"
echo "database ${name} granted to beads@192.168.0.% and beads@100.%"
