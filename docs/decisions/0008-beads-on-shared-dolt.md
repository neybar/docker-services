# 0008: Beads on a shared Dolt server for multi-agent work

- **Status:** Accepted
- **Date:** 2026-10-30
- **Links:** PR #31 (Dolt server), #34/#37 (NAS config), #41/#42 (Beads workspace and agent setup), #43 (agent docs);
  `AGENTS.md` ("Beads in this repo"); `dolt/README.md`; `dolt/AGENTS.md`; `dolt/RESTORE.md`

## Context

Several AI coding agents (Claude Code, Codex, Cursor, Gemini, plus orchestrated ones on other machines) work on this
repo, sometimes at once. They need one issue tracker that is not tied to a single checkout. Beads (`bd`) stores
issues in Dolt. `AGENTS.md` notes the generated Beads blocks assume a local database synced through git, which does
not fit this setup.

## Decision

1. **One shared Dolt sql-server** (`dolthub/dolt-sql-server`, MySQL protocol, TLS required, no Traefik), database
   `ds`, user `beads`. The issue database is not local and is not synced through git; `.beads/issues.jsonl` is never
   committed.
2. **Claim before work**, atomically: `bd ready --claim` or `bd update <id> --claim`. Never work on an issue someone
   else has claimed.
3. **Agent identity**: `BEADS_ACTOR=<tool>@<host>`, so claims and history show which agent acted.
4. **One bd version on every client** (1.3.2 at the time of writing). An upgrade on one client can force a schema
   migration for all; `bd migrate schema` runs once, after every client is upgraded.
5. **Zero outside access to Dolt.** `:3307` is published on every host address; the router does not forward it;
   off-LAN clients come in only over Tailscale or VPN (the tailnet ACL decides which); TLS and per-user passwords are
   required. Security comes from that, not from the bind address (ADR 0004).
6. **Config stays on the NAS, not in git**: `dolt/` holds templates only. `deploy.sh` refuses to deploy while the NAS
   copy differs (ADR 0010).
7. **Secrets**: the password is read from a per-user credentials file and never from the repo. The `beads` user
   gets per-database grants, never `*.*` (Dolt 2.6.1 ignores database-name wildcards, and a global grant can edit
   `mysql.user`; verified, `dolt/README.md`).

## Alternatives considered

- **Local Dolt per checkout with git sync** (the Beads default, per the generated blocks). Overridden in `AGENTS.md`
  for this repo. The sources do not record a comparison beyond that.
- **Server unreachable:** do not `bd init` a local or embedded database, since it splits the history. Note in the PR
  what to file, claim or close.

## Consequences

- Concurrent agents can coordinate, at the cost of a service that must be up and reachable (LAN, Tailscale or VPN).
- Template changes need a hand copy to the NAS and `docker compose restart dolt`.
- Dolt data lives on local NVMe (ADR 0005); live data is excluded from restic and backed up by a nightly snapshot
  (ADR 0006).
- A new database needs `./scripts/dolt-add-db.sh <prefix>`.
