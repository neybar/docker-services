# Dolt (Beads) restore and bring-up

MySQL-protocol server for [Beads](https://github.com/gastownhall/beads) (`bd` v1.3.x). Not HTTP: no Traefik router, no Authelia. Published on `192.168.0.3:3307` and `100.66.84.41:3307` (orcrist's Tailscale address). Clients use `dolt.thelances.net`, the same way as every other service (`BEADS_DOLT_SERVER_TLS=1` sets the MySQL driver's `tls=true`, which verifies the certificate and the hostname). `dolt.thelances.net` is a CNAME that may be repointed, so clients must never hardcode `orcrist`.

Data is `$LOCALDOCKERDIR/dolt/data` on the host SSD. Do not put it on the Synology share (NFSv4 lock revocation). Native backups and dated SQL dumps are written there first (`$LOCALDOCKERDIR/dolt/backups`), then copied to `/mnt/backups/dolt` when that CIFS mount is present.

## What James must do by hand

Do this **before merging**. A merge to `master` deploys, and `docker compose config` (so `deploy.sh`) refuses to render without `DOLT_BEADS_PASSWORD`.

1. On orcrist, in the deploy checkout's `.env` (never commit it):
   ```bash
   openssl rand -hex 32
   # DOLT_BEADS_PASSWORD=<that value>
   ```
   Hex only. The init script rejects quotes, backslashes, and whitespace because the value is interpolated into SQL.
2. `mkdir -p /mnt/backups/dolt` on the Grond mount (`/mnt/backups` is already the CIFS share; see `REBUILD.md` §6).
3. Confirm Traefik already has the `*.thelances.net` wildcard in `$LOCALDOCKERDIR/acme/acme.json`. Dolt waits until `dolt-certs.sh` extracts it. Nothing new to issue.
4. **Done.** `dolt.thelances.net` is a DNS-only CNAME to `orcrist.thelances.net` (A `192.168.0.3`, DNS-only; verified via Cloudflare DoH). The `*.thelances.net` wildcard certificate covers `dolt.thelances.net`.
5. Tailscale is resolved. grokbot-box rejoined as `tag:grokbot`, and the tailnet ACL allows that device orcrist tcp 22/445/3307. Compose publishes `100.66.84.41:3307` as well as `192.168.0.3:3307`. If `tailscaled` is down when the container starts, Docker cannot bind `100.66.84.41` and dolt does not start; start it after `tailscaled`. No systemd change enforces that.
6. After the stack is up, for each Beads project prefix (the `bd init -p` value, unique on this server):
   ```bash
   ./scripts/dolt-add-db.sh <prefix>
   ```
   That creates the database and grants `beads` on it. `beads` has no privileges until you do this.
7. On each client machine:
   ```bash
   export BEADS_DOLT_SERVER_HOST=dolt.thelances.net
   export BEADS_DOLT_SERVER_PORT=3307
   export BEADS_DOLT_SERVER_USER=beads
   export BEADS_DOLT_PASSWORD='<the secret>'
   export BEADS_DOLT_SERVER_TLS=1
   bd init --server --external -p <prefix>
   ```
   Or the same password in `~/.config/beads/credentials` (`[dolt.thelances.net:3307]`, mode `0600`). `--server-tls` is not persisted; keep the env var.
   Tailscale clients (grokbot-box) connect to `100.66.84.41` and must use TLS server name `dolt.thelances.net` (skip-verify is not allowed); map that name to `100.66.84.41` in `/etc/hosts` only if they should not follow the public CNAME.
   Setting `BEADS_DOLT_SERVER_PORT` also marks the server as externally managed, so `bd` does not try to start a local one.

Password rotation later: change `.env`, `docker compose up -d --force-recreate dolt` (the secret is remounted; init does not re-run), then `docker exec dolt /docker-entrypoint-initdb.d/01-beads-user.sh`.

## Name and Tailscale

1. **DNS is done.** `dolt.thelances.net` is a DNS-only CNAME to `orcrist.thelances.net` (A `192.168.0.3`), verified live via Cloudflare DoH. The `*.thelances.net` wildcard certificate covers `dolt.thelances.net`. Clients must never hardcode `orcrist`.
2. **Tailscale is resolved.** grokbot-box is on the tailnet as `tag:grokbot`. The ACL allows that tag to orcrist tcp 22/445/3307. Dolt publishes `100.66.84.41:3307` for that path, in addition to `192.168.0.3:3307`. `beads@'100.%'` matches a CGNAT source; MySQL patterns cannot express `100.64.0.0/10`, so `100.%` is wider than that range.

## Privileges

Verified against `dolthub/dolt-sql-server:2.6.1` (not against the `bd` binary):

- Database-name wildcards are stored and then ignored. `GRANT ... ON \`db%\`.*` did not allow `INSERT` into `dbfoo`.
- `GRANT ... ON *.*` does apply to new databases, and it includes `mysql.user`. `UPDATE mysql.user` changed `root` from `localhost` to `%`. A remote `root` login with an empty password then succeeded. `REVOKE` on `mysql.*` did not remove the global privilege.
- `DROP DATABASE mysql` is rejected by the server. `DROP DATABASE` of an ordinary database is allowed when that database's `DROP` privilege is granted.
- `LOAD_FILE` returned `/etc/passwd` and the password secret for a user with only `USAGE`, while `secure_file_priv` was empty. The server config sets `secure_file_priv` to `/secure-priv`.
- An explicit `GRANT` on one database allowed `CREATE TABLE`, `INSERT`, `CALL DOLT_COMMIT('-Am', ...)`, and `CALL DOLT_CHECKOUT`.
- `root@localhost` from another container was `Access denied`. A user limited to `192.168.0.%` was denied from `172.17.0.0/16`.
- Non-TLS connections to the published port were rejected (`server does not allow insecure connections`). `SHOW VARIABLES LIKE 'require_secure_transport'` still reported `OFF`; the listener flag is what rejected the session.
- `bd init --external` against a pre-created database: **UNVERIFIED** (no `bd` binary in this environment). In beads v1.3.2, `bd init` sets `CreateIfMissing` and runs `CREATE DATABASE` only when `SHOW DATABASES` does not already list the name. Pre-creating the database is what this grant model requires. Schema setup after that (`CREATE TABLE`, `DOLT_COMMIT`) matches statements that succeeded under the explicit grant, but `bd` itself was not executed.

`beads` is one shared account for every project. It can drop tables in any database you have granted. It cannot create users or grant privileges.

## Backups

`task-scheduler` runs `dolt-backup.sh` at 02:15:

1. For each non-system database, `CALL dolt_backup('sync','nightly')` to `file:///backups/native/<db>` (local disk). This mirror deletes branches at the destination that were deleted in the database.
2. `dolt dump -r sql` into `$LOCALDOCKERDIR/dolt/backups/sql/<YYYYMMDD>/<db>.sql`.
3. `SHOW GRANTS` for both `beads` hosts, plus `mysql.user`, into `grants.sql` in that directory.
4. Copy to `/mnt/backups/dolt` when that path is a mount. Dated SQL directories are trimmed to 14 days locally and on Grond. The native mirror is copied with `rsync -a --delete`.

`bd export` is the human-readable issue export and is not a full backup. Once `bd` is installed on a client that already points at this server:

```bash
bd export --all --include-memories -o "$PWD/.beads/issues.jsonl"
```

Run that per workspace. It is not wired into `task-scheduler`.

## Restore

SQL dump of one project (server can stay up; load into an empty database created by `scripts/dolt-add-db.sh`):

```bash
docker exec -i dolt dolt sql < "$LOCALDOCKERDIR/dolt/backups/sql/<YYYYMMDD>/<prefix>.sql"
```

Native backup (all branches and the working set). Stop dolt first so nothing else has the data directory open. From a directory that is **not** inside the live data dir:

```bash
docker run --rm -v "$LOCALDOCKERDIR/dolt/backups/native/<prefix>:/backup:ro" -v /tmp/dolt-restore:/restore \
  dolthub/dolt-sql-server:2.6.1 \
  dolt backup restore file:///backup /restore
```

Stop the server, replace `$LOCALDOCKERDIR/dolt/data/<prefix>` with the restored directory, start the server, and run `scripts/dolt-add-db.sh <prefix>` again if the grants dump is what you are recovering (the native backup does not include users). Replay `grants.sql` only after reading it; it is a `SHOW GRANTS` transcript, not a `mysqldump` of the `mysql` database (`mysqldump` is not in the image).

Users are recreated from the secret by the init script on an empty data directory. On an existing data directory, run `01-beads-user.sh` as above, then `dolt-add-db.sh` for each prefix.

Cert and server YAML live in git (`dolt/servercfg/config.yaml`) and in `$LOCALDOCKERDIR/acme/acme.json` (Traefik). They are not in the Dolt backup. Losing `$LOCALDOCKERDIR/dolt/data` loses every project until you restore a backup.
