# dolt/AGENTS.md

Subtree rules for `dolt/` (the Beads Dolt server). Root `AGENTS.md` still applies, in particular hard rule 8 and the
Dolt invariant. Background: `dolt/README.md`. Paths here are repo-root-relative.

- `dolt/servercfg/config.yaml` and `dolt/init/01-beads-user.sh` are templates; the live copies are on the NAS (the
  repo is public and live config can be identifying). A merged template change deploys only after you copy it to the
  NAS and run `docker compose restart dolt`. Until the NAS copy matches, `deploy.sh` refuses to deploy and
  `validate-dolt.sh` fails; both print the `diff`/`cp` commands (`scripts/lib/dolt-nas.sh`).
- Goal: zero outside access. `:3307` is published on every host address (root hard rule 4); the router does not
  forward it, and off-LAN clients come in only over Tailscale or VPN (the tailnet ACL decides which). TLS required,
  no Traefik.
- New Beads database: `./scripts/dolt-add-db.sh <prefix>`. Never give `beads` a `*.*` grant (`dolt/README.md`,
  "Users and privileges").
- After a change: `./scripts/validate-dolt.sh` (live stack).
