# AGENTS.md

Home server Docker infrastructure: self-hosted services on Docker Compose behind Traefik, with a CrowdSec WAF and
Authelia SSO/2FA in front of every web service and a Synology NAS (192.168.0.6) for storage.

This file is the **root agent instructions** (Claude Code, Codex, Cursor, Gemini): `CLAUDE.md` imports it, `GEMINI.md`
is a symlink to it, Cursor reads it natively. Human docs: `README.md` (services, variables), `REBUILD.md` (fresh host),
`docs/DEPLOY.md`, `docs/CROWDSEC.md`, `dolt/README.md`. Nested `AGENTS.md` (each with a `CLAUDE.md` of `@AGENTS.md`
and a `GEMINI.md` symlink) add subtree-only rules. An agent may not load one until it works in that subtree, so a rule
that can be broken from outside it stays here. `scripts/ci/test-agent-docs.sh` checks sizes and named paths.

Significant architecture changes add or supersede an ADR in `docs/decisions/` in the same PR.

## Hard rules

1. **A merge to `master` is a live deploy** on orcrist (`.github/workflows/deploy.yml` runs `scripts/deploy.sh`).
   Docker access is root on the host: compose changes, `build:` contexts and workflow edits run as root.
2. **Never use the deploy checkout** (`/home/jalance/Projects/docker-services`): no edits, `git switch` or commits; use
   your own clone. A branch there pauses deploys; switching it to a commit without `traefik-rules/` deletes that directory under the
   live Traefik.
3. **Git.** Agents may commit, push feature branches and open PRs; never push or merge master. With jalance driving,
   push to `neybar/docker-services` as `neybar`; unattended orchestrator work (e.g. grokbot) pushes from the
   `neybar-bot` fork. Do not ask which. After `gh pr create` and every push, run `gh pr checks <n> --watch` and
   confirm `gh pr view <n> --json mergeStateStatus` is `CLEAN`; on failure read `gh run view <run> --log-failed`,
   fix, push, watch again. Never call a PR ready while a check fails or is pending. Before post-merge cleanup, confirm
   `gh pr view <n> --json state` is `MERGED` (its exit code proves nothing).
4. **Plain `docker compose`, no host addresses in compose**: run `docker compose <args>` from the checkout root, no
   wrapper. Never bind a port to a host IP (LAN or Tailscale) or require one as a variable: they change, and a stale
   one stops the service. Restrict access at the network (no port forward, tailnet ACL) and in the service (TLS, auth).
5. **Every HTTP router uses a `chain-*@file` middleware**: `chain-authelia` (default), `chain-no-auth` or
   `chain-basic-auth`. Each starts with `crowdsec@file`, so a router without one bypasses the WAF (and usually
   Authelia). Only intended exception: `http-catchall` (HTTPS redirect, no backend). Never remove `crowdsec@file`
   from a chain.
6. **No secrets in the repo, which is public**: no tokens, passwords, keys or identifying live config in files, commit
   messages or PR text (`.env`, `acme/` and local service state are gitignored). Never print secrets.
7. **CI has no `.env`**: a new required `${VAR:?}` in compose needs a dummy value in the "Validate docker-compose.yml"
   step of `.github/workflows/lint.yml` (and a line in `env.example`), or CI fails.
8. **Dolt templates are not live config**: the live copies of `dolt/servercfg/config.yaml` and
   `dolt/init/01-beads-user.sh` are on the NAS, copied by hand, then `docker compose restart dolt`. Until the NAS copy
   matches, `deploy.sh` refuses to deploy and `validate-dolt.sh` fails.
9. **No embedded random-access database (H2 and the like) on NFS**: use `$NVME_DIR` (see Storage).

## Repo map

| Path | What |
|---|---|
| `docker-compose.yml` | every service |
| `env.example` | variables; the table is in `README.md` |
| `traefik-rules/` | Traefik file-provider config (chains, middlewares, `crowdsec.yml`, routers outside compose); read-only at `/rules`, **not watched** |
| `crowdsec-config/acquis.d/` | CrowdSec acquisition (`traefik.yaml`, `appsec.yaml`), read-only |
| `plugins-local/` | vendored bouncer plugin; bump: `plugins-local/README.md` |
| `task-scheduler/` | cron container: schedule in its `Dockerfile`, jobs in `task-scheduler/scripts/` (times: `README.md` Maintenance) |
| `dolt/` | Dolt templates, `dolt/README.md`, `dolt/RESTORE.md` |
| `kometa/config.yml.example` | Kometa template (live copy on the NAS) |
| `scripts/deploy.sh` | the deploy, run by `deploy.yml` from the deploy checkout |
| `scripts/validate-traefik.sh`, `scripts/validate-waf.sh`, `scripts/validate-dolt.sh` | live-stack checks |
| `scripts/dolt-add-db.sh`, `scripts/dolt-prebackup.sh` | new Beads database; nightly Dolt backup (jalance's crontab) |
| `scripts/lib/` | `host-addrs.sh` (validate test targets only), `nvme-paths.sh` (`NVME_PATHS`), `dolt-nas.sh`, `deploy-target.sh` (deploy.sh target + on-master guard), `validate-common.sh` (`.shellcheckrc` follows its `source`) |
| `scripts/ci/` | `integration-plan.sh`, `integration-run.sh`, the `test-*.sh` run by `lint.yml` |
| `.github/workflows/` | `lint.yml` (GitHub-hosted), `integration.yml` (trusted PRs on orcrist, read-only), `deploy.yml` |

## Validation matrix

| You changed | Run |
|---|---|
| `docker-compose.yml` | `docker compose config --quiet`, then `./scripts/validate-traefik.sh` (always) |
| Traefik, CrowdSec, `traefik-rules/`, `crowdsec-config/`, `plugins-local/`, the chains | `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh` |
| Dolt, `dolt/`, its NAS config or certs | `./scripts/validate-dolt.sh` |
| NVMe mounts or `scripts/lib/nvme-paths.sh` | `./scripts/ci/test-nvme-paths.sh` |
| `scripts/ci/integration-plan.sh` | `./scripts/ci/test-integration-plan.sh` |
| `scripts/deploy.sh` target selection or `scripts/lib/deploy-target.sh` | `./scripts/ci/test-deploy-target.sh` |
| any `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` | `./scripts/ci/test-agent-docs.sh` |
| any shell script | `shellcheck` (CI runs it at severity `info`) |

`validate-*` probe the **live** stack (deployed code, not your branch) and need orcrist and `.env`: elsewhere skip them
and say so in the PR (`integration.yml` runs them for trusted PRs). `scripts/ci/test-*.sh` and shellcheck need no docker.

**New service**: follow "Adding a service" in `README.md`. Must-dos: `*default-logging`, `no-new-privileges:true`, a
`chain-*@file` middleware, a `NVME_PATHS` row if on NVMe, a CI dummy for new `:?` vars, `SERVICES` in
`scripts/validate-traefik.sh`.

## Subsystem invariants

**Traefik and CrowdSec** (`docs/CROWDSEC.md`; subtree rules: `traefik-rules/AGENTS.md`)
- `crowdsec@file` stays in `traefik-rules/crowdsec.yml`, never a compose label (it would 404 every chain at start).
- `traefik-rules/` is not watched: `deploy.sh` restarts traefik when it changed; by hand `docker compose restart traefik`.
- The plugin **fails open** on purpose (LAPI or AppSec down: traffic passes; Authelia still authenticates). Keep it.
- A wrong or unregistered bouncer key is an **outage** (403 on every chained router); an empty key fails closed.
  `cscli bouncers delete traefik` deletes the live bouncer too: `docker compose restart crowdsec` right after.
  Rotation: `REBUILD.md` §7.
- Compose: keep `DISABLE_SCENARIOS` (never re-enable `crowdsec-appsec-outofband` or add `crs-inband` casually).
  CrowdSec gets no Docker API access (keep it off `socket_proxy`); socket-proxy `EXEC` stays off.

**Storage** (`REBUILD.md` §5-6)
- NFS (Synology) for configs and media. Local NVMe: `$NVME_DIR/<service>/<role>` (default `/usr/local/docker`, on
  `/`), **not** `LOCALDOCKERDIR` (the repo checkout under `/home`).
- An empty `$NVME_DIR/plex/config` starts a healthy-looking, empty Plex: restore it from restic first (§6).
- NZBHydra2 (H2 wedges on NFSv4 lock loss): keep its nested NVMe mount and `stop_grace_period: 120s` (§5).
- Every container uses `*default-logging`; do not add an external logrotate.
- The Traefik access log holds API keys in clear text: never copy it into the repo, a PR or a report; do not loosen
  its directory mode (700).

**Dolt** (`dolt/README.md`; subtree rules: `dolt/AGENTS.md`): zero outside access, TLS required, no Traefik. Never
give `beads` a `*.*` grant.

**Host DNS** (REBUILD.md §2): NextDNS serves live DNS (no local DNS server); Tailscale needs systemd-resolved's stub
listener (`127.0.0.53:53`), so nothing in compose may publish `:53`.

## Beads in this repo

This section beats the generated Codex block below: the issue database is **not** local or synced through git (ignore
its "local Dolt DB" / `refs/dolt/data` line; never run `bd dolt push`), and git follows hard rule 3. `bd setup codex`
writes the block: never edit between its markers. The Claude block is removed on purpose (the SessionStart hook in
`.claude/settings.json` runs `bd prime`): `bd setup claude` would re-add it, so never rerun it. `--check` is safe (its
"no beads section" warning is expected); `--stealth` adds a second hook, `--remove` deletes the hook.

- **Shared server** `dolt.thelances.net:3307`, database `ds`, user `beads`, verified TLS. Claim atomically before you
  start (`bd ready --claim --json` or `bd update <id> --claim`); never work on an issue someone else claimed.
- **Identity**: `BEADS_ACTOR=<tool>@<host>` (e.g. `codex@orcrist`) or `--actor <tool>@<host>`.
- **Password** from `~/.config/beads/credentials` (per user, mode 600), never the repo: not in a file here, an env var
  in a committed file, or a logged command line. Never set `BEADS_DOLT_CREDENTIAL_COMMAND` (bd 1.3.2 sends its output
  as the MySQL *username*, leaking it into server errors). Client setup: `dolt/README.md`.
- **Server unreachable** (e.g. a cloud VM off the LAN/tailnet): never `bd init` or create a local or embedded database
  (it splits the history). Do the work; note in the PR what to file, claim or close.
- **Never commit `.beads/issues.jsonl`** (or any JSONL export). The server is the source of truth.
- **One bd version** on every client (currently 1.3.2): upgrading one can force a schema migration on all.
- **Schema migrations** hit every client at once: never migrate the shared schema casually, and never persist
  `BD_ALLOW_REMOTE_MIGRATE`. Procedure: "Schema migrations" in `dolt/README.md`.
- **Routing**: leaf issues carry tier:/effort:/needs-human/live-risk labels; see `bd memories agent-routing-labels`.
  Unattended agents exclude needs-human and live-risk.
- **Memory**: persistent project knowledge goes in `bd remember`, not ad hoc files.

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

