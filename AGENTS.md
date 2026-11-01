# AGENTS.md

Home server Docker infrastructure: self-hosted services on Docker Compose behind Traefik, with a CrowdSec WAF and
Authelia SSO/2FA in front of every web service and a Synology NAS (192.168.0.6) for storage.

This file is the **single source of instructions for AI coding agents** (Claude Code, Codex, Cursor, Gemini).
`CLAUDE.md` imports it, `GEMINI.md` is a symlink to it, Cursor reads it natively. Keep rules here short and link the
human docs: `README.md` (services, variables), `REBUILD.md` (fresh host), `docs/DEPLOY.md`, `docs/CROWDSEC.md`,
`dolt/README.md`. `scripts/ci/test-agent-docs.sh` caps this file at 16 KiB and checks the paths it names.

## Hard rules

1. **A merge to `master` is a live deploy** on orcrist (`.github/workflows/deploy.yml` runs `scripts/deploy.sh`).
   Docker access is root on the host: compose changes, `build:` contexts and workflow edits run as root.
2. **Never use the deploy checkout** (`/home/jalance/Projects/docker-services`): no edits, no `git switch`, no
   commits there. Work in your own clone. A feature branch there pauses deploys, and switching it to a commit without
   `traefik-rules/` deletes the directory under the running Traefik.
3. **Git.** This repo authorizes agents to commit and push feature branches from the neybar-bot fork and open PRs;
   never push or merge master. After `gh pr create` and every push, run `gh pr checks <n> --watch` and confirm
   `gh pr view <n> --json mergeStateStatus` is `CLEAN`; on failure read `gh run view <run> --log-failed`, fix, push,
   watch again. Never call a PR ready while a check fails or is pending. Before post-merge cleanup, confirm
   `gh pr view <n> --json state` is `MERGED` (its exit code proves nothing).
4. **Compose only as `./scripts/compose.sh <args>`**, never bare `docker compose`. Compose requires
   `HOST_IP`/`TAILSCALE_IP` for every command (even `ps`); the wrapper derives them from the host
   (`scripts/lib/host-addrs.sh`) and fails loudly if it cannot derive `HOST_IP` (no `0.0.0.0` fallback). Never put
   them in `.env`.
5. **Every HTTP router uses a `chain-*@file` middleware**: `chain-authelia` (the default), `chain-no-auth` or
   `chain-basic-auth`. Each starts with `crowdsec@file`, so a router without one bypasses the WAF (and usually
   Authelia). The only intended exception is `http-catchall` (redirect to HTTPS, no backend). Never remove
   `crowdsec@file` from a chain.
6. **No secrets in the repo, which is public**: no tokens, passwords, keys or identifying live config, in files, commit
   messages or PR text. `.env`, `acme/` and the local service state are gitignored. Never print secrets.
7. **CI has no `.env`.** A new required `${VAR:?}` in compose needs a dummy value in the "Validate docker-compose.yml"
   step of `.github/workflows/lint.yml` (and a line in `env.example`), or CI fails.
8. **Dolt templates are not live config.** `dolt/servercfg/config.yaml` and `dolt/init/01-beads-user.sh` are templates;
   the live copies are on the NAS and copied by hand. Until the NAS copy matches, `deploy.sh` refuses to deploy and
   `validate-dolt.sh` fails.
9. **No embedded random-access database (H2 and the like) on NFS**: use `$NVME_DIR` (see Storage).

## Repo map

| Path | What |
|---|---|
| `docker-compose.yml` | every service |
| `env.example` | variables; the table is in `README.md` |
| `traefik-rules/` | all Traefik file-provider config (chains, middlewares, `crowdsec.yml`, routers outside compose). Read-only at `/rules`, **not watched** |
| `crowdsec-config/acquis.d/` | CrowdSec acquisition (`traefik.yaml`, `appsec.yaml`), read-only |
| `plugins-local/` | vendored CrowdSec bouncer plugin; bump: `plugins-local/README.md` |
| `task-scheduler/` | cron container: schedule in its `Dockerfile`, jobs in `task-scheduler/scripts/` (cleanup 00:00, log rotation 00:10, Dolt certs 00:20, Plex restart Sun 03:00) |
| `dolt/` | Dolt templates, `dolt/README.md`, `dolt/RESTORE.md` |
| `kometa/config.yml.example` | Kometa template (live copy on the NAS) |
| `scripts/compose.sh` | compose wrapper (hard rule 4) |
| `scripts/deploy.sh` | the deploy, run by `deploy.yml` from the deploy checkout |
| `scripts/validate-traefik.sh`, `scripts/validate-waf.sh`, `scripts/validate-dolt.sh` | live-stack checks |
| `scripts/dolt-add-db.sh`, `scripts/dolt-prebackup.sh` | new Beads database; nightly Dolt backup (jalance's crontab) |
| `scripts/lib/` | `host-addrs.sh`, `nvme-paths.sh` (`NVME_PATHS`), `dolt-nas.sh`, `validate-common.sh` (shared helpers; `.shellcheckrc` lets ShellCheck follow its `source`) |
| `scripts/ci/` | `integration-plan.sh`, `integration-run.sh`, and the `test-*.sh` run by `lint.yml` |
| `.github/workflows/` | `lint.yml` (GitHub-hosted), `integration.yml` (trusted PRs on orcrist, read-only), `deploy.yml` |

## Validation matrix

| You changed | Run |
|---|---|
| `docker-compose.yml` | `./scripts/compose.sh config --quiet`, then `./scripts/validate-traefik.sh` (always) |
| Traefik, CrowdSec, `traefik-rules/`, `crowdsec-config/`, `plugins-local/`, the chains | `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh` |
| Dolt, `dolt/`, its NAS config or certs | `./scripts/validate-dolt.sh` |
| NVMe mounts or `scripts/lib/nvme-paths.sh` | `./scripts/ci/test-nvme-paths.sh` |
| `scripts/ci/integration-plan.sh` | `./scripts/ci/test-integration-plan.sh` |
| `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` | `./scripts/ci/test-agent-docs.sh` |
| any shell script | `shellcheck` (CI runs it at severity `info`) |

The `validate-*` scripts probe the **live** stack (deployed code, not your branch) and need orcrist and `.env`;
elsewhere skip them and say so in the PR. `integration.yml` runs them for trusted PRs (`docs/DEPLOY.md`). The
`scripts/ci/test-*.sh` scripts and shellcheck need no docker.

## Adding a service

1. Copy an existing service in `docker-compose.yml` (e.g. `smokeping` or `radarr`), keeping `logging: *default-logging`
   and `security_opt: no-new-privileges:true`. Join the `t2_proxy` network.
2. Labels:
   ```yaml
   - "traefik.enable=true"
   - "traefik.http.routers.<name>-rtr.entrypoints=https"
   - "traefik.http.routers.<name>-rtr.rule=Host(`<name>.$DOMAINNAME`)"
   - "traefik.http.routers.<name>-rtr.tls=true"
   - "traefik.http.routers.<name>-rtr.middlewares=chain-authelia@file"
   - "traefik.http.routers.<name>-rtr.service=<name>-svc"
   - "traefik.http.services.<name>-svc.loadbalancer.server.port=<port>"
   ```
3. Config persistence: an NFS volume (follow the existing pattern). If it needs the local NVMe instead (an embedded
   database, or speed), mount `${NVME_DIR:-/usr/local/docker}/<service>/<role>` and add a row to `NVME_PATHS` in
   `scripts/lib/nvme-paths.sh` (`./scripts/ci/test-nvme-paths.sh` fails until both agree).
4. New required variables: hard rule 7.
5. Add the subdomain to `SERVICES` in `scripts/validate-traefik.sh` and a row to the Services table in `README.md`.
6. After the deploy, run `./scripts/validate-traefik.sh`.

## Subsystem invariants

**Traefik and CrowdSec** ([docs/CROWDSEC.md](docs/CROWDSEC.md))
- `crowdsec@file` is in `traefik-rules/crowdsec.yml` on purpose (as a label it 404s every chain until Traefik is
  healthy).
- `traefik-rules/` is not watched: `deploy.sh` restarts traefik when it changed; by hand,
  `./scripts/compose.sh restart traefik`.
- The plugin **fails open** on purpose (LAPI or AppSec down: traffic passes; Authelia is still the auth layer). Keep it.
- A wrong or unregistered bouncer key is an **outage** (403 on every chained router); an empty key fails closed.
  `cscli bouncers delete traefik` deletes the live bouncer too: run `./scripts/compose.sh restart crowdsec` right
  after. Rotation: `REBUILD.md` §7.
- `DISABLE_SCENARIOS` is deliberate. Do not re-enable `crowdsec-appsec-outofband` or add `crs-inband` casually.
- CrowdSec has no Docker API access: keep it off `socket_proxy`. Socket-proxy `EXEC` stays off.
- The LAN whitelist suppresses bans, not AppSec blocks: probes from this host get 403.
- Known bypass: `dsm-photo-rtr` in `traefik-rules/synology.yml` (no chain; Beads `ds-o9h`).

**Storage** ([REBUILD.md](REBUILD.md) §5-6)
- NFS (Synology) for service configs and media. Local NVMe at `$NVME_DIR/<service>/<role>` (default
  `/usr/local/docker`, on `/`). `$NVME_DIR` is **not** `LOCALDOCKERDIR`, which is the repo checkout on the SATA SSD.
- The Plex library DB (`$NVME_DIR/plex/config`) is in **no backup**: an empty path starts a healthy-looking, empty Plex.
- NZBHydra2: NFSv4 lock loss (EIO, ~every 9 days) wedges H2. Keep its nested NVMe mount and `stop_grace_period: 120s`.
- Logging: every container uses `*default-logging`; do not add an external logrotate.
- The Traefik access log stores API keys in clear text (`?apikey=`): never copy it into the repo, a PR or a report,
  and do not loosen its directory mode (700).

**Dolt** ([dolt/README.md](dolt/README.md))
- `:3307` on `$HOST_IP` and `$TAILSCALE_IP` only, never `0.0.0.0`. TLS required, no Traefik.
- A template change deploys only after the NAS copy is updated and `./scripts/compose.sh restart dolt` (hard rule 8).
- New Beads database: `./scripts/dolt-add-db.sh <prefix>`. Never give `beads` a `*.*` grant.

**Pi-hole** ([REBUILD.md](REBUILD.md) §2): cold standby (NextDNS serves live DNS). v6 reads only `FTLCONF_*` env vars;
v5-style vars are silently ignored. Binds `:53` on `$HOST_IP` only.

## Beads in this repo

Where this section and the generated Beads blocks below disagree, this section wins. In particular, the issue
database is **not** local and is not synced through git (ignore the blocks' "local Dolt DB" / `refs/dolt/data` lines;
never run `bd dolt push`), and commits, pushes and PRs follow hard rule 3, not the blocks' conservative profile. The
blocks are written by `bd setup codex` / `bd setup claude`: never edit between their markers.

- **Shared server.** Issues live on `dolt.thelances.net:3307`, database `ds`, user `beads`, verified TLS. Several
  agents use it at once, so claim atomically before you start: `bd ready --claim --json` or `bd update <id> --claim`.
  Never work on an issue someone else has claimed.
- **Identity.** Set `BEADS_ACTOR=<tool>@<host>` (e.g. `codex@orcrist`, `cursor@laptop`) or pass `--actor <tool>@<host>`,
  so claims and history show which agent did what.
- **Password.** It comes from `~/.config/beads/credentials` (per user, mode 600). Never from the repo: do not write it
  to any file here, an env var in a committed file, or a command line that gets logged. Never set
  `BEADS_DOLT_CREDENTIAL_COMMAND`: bd 1.3.2 sends its output as the MySQL *username*, leaking it into server errors.
  Client setup: `dolt/README.md`.
- **Server unreachable** (e.g. a cloud VM outside the LAN/tailnet): do **not** run `bd init` or create a local or
  embedded database (it splits the history). Do the work, and note in the PR what to file, claim or close.
- **Never commit `.beads/issues.jsonl`** (or any other JSONL export). The server is the source of truth.
- **One bd version.** Every client stays on the same bd version (currently 1.3.2). Upgrading one client can force a
  schema migration that hits every client.
- **Schema migrations.** `bd init` and other commands refuse to migrate a server database that already has a schema
  (after a bd upgrade, or a half-finished init), because that promotes the schema for every client at once. After
  every client is upgraded, run `bd migrate schema` once from a set-up workspace; for a half-finished init with no
  other clients, `BD_ALLOW_REMOTE_MIGRATE=1 bd init …` inline, for that one run. Never persist
  `BD_ALLOW_REMOTE_MIGRATE` in a shell profile or the repo.
- **Memory.** Persistent project knowledge goes in `bd remember`, not in ad hoc files.

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
