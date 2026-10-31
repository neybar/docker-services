# Dolt (Beads) restore

How the service is set up (NAS config, local data, guard, privileges, backup cron): the Dolt note in `CLAUDE.md`. Bring-up on a fresh host: `REBUILD.md` §7.

Run everything from the deploy checkout on orcrist. None of these procedures has been exercised end to end yet.

## What the backup holds

`scripts/dolt-prebackup.sh` overwrites `/mnt/docker/dolt/backups` (`/backups` in the container) every night. There is one generation only, with no dated copies:

- `native/<prefix>/`: `dolt_backup` mirror of each database (all branches and the working set). Branches deleted on the server disappear from it too.
- `sql/<prefix>.sql`: `dolt dump -r sql` of each database's working set.
- `grants.sql`: a `SHOW GRANTS` transcript for both `beads` hosts, plus `mysql.user`. It is a transcript to read, not a script to replay. Neither backup contains users.

`bd export --all --include-memories -o .beads/issues.jsonl` on a client is a human-readable issue export, not a backup.

## One database, server running (SQL dump)

```bash
./scripts/dolt-add-db.sh <prefix>     # empty database + grants, if it is gone
docker compose exec -T -w /var/lib/dolt/<prefix> dolt dolt sql < /mnt/docker/dolt/backups/sql/<prefix>.sql
```

This loses history: the dump is the working set only.

## Databases with history (native backup)

`backup restore` needs nothing else to have the data directory open, so stop dolt first. The image's entrypoint starts a server, so override it:

```bash
docker compose stop dolt
sudo mkdir -p /usr/local/dolt/restore
docker run --rm --entrypoint dolt -w /restore \
  -v /mnt/docker/dolt/backups/native/<prefix>:/backup:ro \
  -v /usr/local/dolt/restore:/restore \
  dolthub/dolt-sql-server:2.6.1 backup restore file:///backup <prefix>
sudo mv /usr/local/dolt/data/<prefix> /usr/local/dolt/restore/<prefix>.old 2>/dev/null || true
sudo mv /usr/local/dolt/restore/<prefix> /usr/local/dolt/data/<prefix>
docker compose up -d dolt
./scripts/dolt-add-db.sh <prefix>     # re-grants beads; CREATE DATABASE IF NOT EXISTS is a no-op
```

Delete `/usr/local/dolt/restore` once the restored data checks out.

## Whole data directory lost

`/usr/local/dolt/data` is empty, so the next start runs init, which creates `beads@'192.168.0.%'` and `beads@'100.%'` from the compose secret. Restore each `native/<prefix>` into `/usr/local/dolt/data/<prefix>` as above while dolt is stopped. Then start dolt and run `./scripts/dolt-add-db.sh <prefix>` for each prefix. `root` is recreated by the image as `root@localhost` with no password.

## Users on an existing data directory

To re-create the `beads` users, or to apply a new `DOLT_BEADS_PASSWORD`, update `.env` and run `docker compose up -d --force-recreate dolt` to remount the secret. Init does not rerun, because `.init_completed` exists. Then:

```bash
docker compose exec -T dolt /docker-entrypoint-initdb.d/01-beads-user.sh
```

Finish with `./scripts/validate-dolt.sh`.
