# Dolt (Beads server)

Shared Dolt sql-server for `bd` (Beads) on several machines: `dolthub/dolt-sql-server:2.6.1`, MySQL protocol, TLS
required, no Traefik/Authelia. Restore: [RESTORE.md](RESTORE.md). Bring-up on a fresh host: `REBUILD.md` §7. Rules for
agents (claiming, credentials, schema migrations): `AGENTS.md`, "Beads in this repo".

## Network

- Publishes `:3307` on `$HOST_IP` and `$TAILSCALE_IP`, never `0.0.0.0`. Both are derived at every compose run by
  `scripts/lib/host-addrs.sh` (`REBUILD.md` §7, Host addresses).
- The tailnet ACL decides which tailnet devices reach it (grokbot-box, `tag:grokbot`: orcrist tcp 22/445/3307).
- If `tailscaled` is down when the container starts (e.g. at boot), Docker cannot bind `$TAILSCALE_IP` and dolt does not
  start; nothing orders the two. Compose runs (deploys included) never fail on Tailscale: while it is down the helper
  binds `127.0.0.1` instead and warns, so a deploy brings dolt back LAN-only, and the next deploy after `tailscaled`
  returns restores the tailnet address.
- Clients use `dolt.<domain>`: a DNS-only CNAME to `orcrist.<domain>` (A `$HOST_IP`), covered by the `*.<domain>`
  wildcard cert. It may be repointed, so clients never hardcode `orcrist`. Tailscale clients connect to `$TAILSCALE_IP`
  with TLS server name `dolt.<domain>` (an `/etc/hosts` entry), never skip-verify.

## Config stays on the NAS, not in git

NFS volume `dolt_config` (`:/volume1/docker/dolt`, CIFS on the host at `/mnt/docker/dolt`) holds `servercfg/`, `init/`,
`certs/` and `backups/`. Compose mounts each one by volume `subpath` at the path the image reads:
`/etc/dolt/servercfg.d`, `/docker-entrypoint-initdb.d` and `/certs` read-only, and `/backups`.

This directory (`dolt/`) holds **templates** only (`servercfg/config.yaml`, `init/01-beads-user.sh`), copied by hand
like `kometa/config.yml.example`, because the repo is public and live config can be identifying.

- A merged template change does **not** deploy: copy it to the NAS, then `./scripts/compose.sh restart dolt`.
- Drift cannot pass silently: `deploy.sh` refuses to deploy (before touching any container) and `validate-dolt.sh`
  fails while `servercfg/config.yaml` or `init/01-beads-user.sh` on the NAS differs from its template, and both print
  the `diff`/`cp` commands (`scripts/lib/dolt-nas.sh`, read-only). A PR that changes a template therefore fails its
  `dolt` integration check, and its merge deploy, until the NAS copy is updated.

## Data

`$NVME_DIR/dolt/data` → `/var/lib/dolt` (local NVMe; `REBUILD.md` §5). That is the image's `VOLUME`, and its entrypoint
hardcodes `/var/lib/dolt/.init_completed`. A hydra-style nested `data_dir` made every start look like a first run. Init
(`01-beads-user.sh`) runs only while that marker is missing. Losing the directory loses every Beads database until it
is restored from `/mnt/docker/dolt/backups`.

## Entrypoint guard

Inline in compose, then `exec tini -- docker-entrypoint.sh`. Whenever `servercfg.d` does not hold exactly one `*.yaml`,
the image starts on its defaults: plaintext on `0.0.0.0`, with the existing users. The guard refuses to start unless
these exist: `config.yaml` with `require_secure_transport: true`, both PEMs, and, on a first start, the init script.

## Certs

`dolt-certs.sh` (task-scheduler, at its start and daily at 00:20) dumps the wildcard from `acme.json` into `certs/` and
restarts dolt only when the cert changed. The restart is `POST /containers/dolt/restart` through the socket proxy:
`CONTAINERS=1` and `POST=1` allow it, `EXEC` is off.

## Users and privileges

- The password is `DOLT_BEADS_PASSWORD` (`openssl rand -hex 32`, hex only), the compose secret `dolt_beads_password`,
  not a container env var.
- The users are `beads@'192.168.0.%'` and `beads@'100.%'`. MySQL host patterns cannot express Tailscale's
  `100.64.0.0/10`, so `100.%` is wider.
- `beads` has no `*.*` grants: Dolt 2.6.1 ignores database-name wildcards, and a global grant can `UPDATE mysql.user`
  and move `root` off localhost (verified).
- `./scripts/dolt-add-db.sh <prefix>` creates one database and grants it
  `SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES, EXECUTE, CREATE VIEW, SHOW VIEW`
  (bd's migrations create views; without `CREATE VIEW` init
  stops at migration 0017). `bd init --external` against that pre-created database is verified (bd 1.3.2, database
  `ds`).
- `secure_file_priv=/secure-priv` (empty tmpfs), because otherwise `LOAD_FILE` can read the secret.

## bd clients

Upstream is `gastownhall/beads` (`steveyegge/beads` redirects there). Every client stays on the same bd version
(currently 1.3.2).

- Per user: `BEADS_DOLT_SERVER_{MODE=1,HOST=dolt.<domain>,PORT=3307,USER=beads,TLS=1}` and `BEADS_DOLT_AUTO_START=0`.
  `TLS=1` verifies the cert against `HOST`.
- Day-to-day commands read the password from `~/.config/beads/credentials` (mode 600, `[dolt.<domain>:3307]` then
  `password = …`).
- `bd init` ignores that file: pass `BEADS_DOLT_PASSWORD` inline for the init run only.
- `BEADS_DOLT_CREDENTIAL_COMMAND` is **not** a password command: in 1.3.2 its output is sent as the MySQL *username*,
  which would put the password in the server's `Access denied` errors.
- bd sends usage metrics by default; run `bd metrics off` per user.
- Schema migrations after a bd upgrade: see "Beads in this repo" in `AGENTS.md`.

## Backup

`scripts/dolt-prebackup.sh` overwrites `backups/` on the NAS (latest only): a native `dolt_backup`, a SQL dump and a
grants transcript. It runs from jalance's crontab at 03:00 America/Denver (`REBUILD.md` §1). It is not in
task-scheduler because it needs `docker exec`, and socket-proxy `EXEC` stays off. Contents and restore:
[RESTORE.md](RESTORE.md).

## Validation

Run `./scripts/validate-dolt.sh` after changes touching Dolt, its NAS config or its certs. It checks: healthy; TLS
verifies for `dolt.<domain>` on `HOST_IP` and `TAILSCALE_IP`; plaintext and remote `root` rejected; `beads` logs in over
verified TLS; init did not rerun; the NAS `servercfg/config.yaml` and `init/01-beads-user.sh` match `dolt/`.

Its MySQL client is a pinned image run with `docker run --rm --network host`; it also does the TLS check
(`VERIFY_IDENTITY` with a non-existent user: `Access denied` means the handshake verified).
`openssl s_client -starttls mysql` does not handshake with Dolt (`MySQL packet too short`) yet prints `Verify return code: 0 (ok)`, so it
cannot be used.
