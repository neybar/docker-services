# 0001: Public/private repo split

- **Status:** Accepted
- **Date:** 2026-11-07
- **Links:** Beads epic `ds-nhh` (homelab as code), decision issue `ds-nhh.1`; follow-ups `ds-nhh.2`, `ds-nhh.4.1`,
  `ds-nhh.5.2`, `ds-nhh.5.5`-`ds-nhh.5.8`, `ds-nhh.6.1`-`ds-nhh.6.3`

## Context

This repo is public and doubles as a showcase. It also deploys the live stack: a merge to `master` runs
`scripts/deploy.sh` on orcrist through a self-hosted runner registered to this repo. The homelab-as-code epic adds
Ansible for the host and, later, k3s manifests. Those need instance data (inventory, host variables, encrypted
secrets) that must not be public.

The deploy path depends on this repo's identity in several places:

- `scripts/deploy.sh` fetches `master` from the public repo URL (`REPO_URL`);
- the runner is registered to this repo (`~/actions-runner`, unit
  `actions.runner.neybar-docker-services.orcrist.service`);
- `integration.yml` runs live validation only for same-repo PRs (`head.repo.full_name == github.repository`);
- `docs/DEPLOY.md`, `AGENTS.md` and the deploy-checkout path name it.

The security model in `docs/DEPLOY.md` is already careful (`deploy.yml` is push/dispatch only, `integration.yml` uses
`pull_request_target` with master's scripts, fork runs need approval). The remaining risk is human: approving a fork
PR run that edits `.github/` can target the runner.

## Decision

1. **Public repo.** Keep `neybar/docker-services` as the public monorepo. Add `ansible/` to it (roles, no instance
   data). Rename it (e.g. `homelab`) only when k3s manifests arrive; GitHub redirects the old name.
2. **Private repo.** `neybar/homelab-site` holds instance config: inventory, host variables, encrypted secrets, and
   the live-deploy runbook.
3. **Deploys and the runner move to the private repo** (`ds-nhh.5.5`-`ds-nhh.5.7`). The public repo then has no
   self-hosted runner, which removes the fork-PR-to-runner class of risk. Pre-merge live validation needs a new home:
   `ds-nhh.5.6` decides it.
4. **How the private repo consumes the public one.**
   - Compose deploys: a `repository_dispatch` from the public repo carrying the merged SHA (`ds-nhh.5.5`).
   - Ansible roles: `requirements.yml` pinned to a public git tag; while developing, `roles_path` points at a local
     clone.
   - Later, Flux: one `GitRepository` per repo.
5. **History.** Keep all existing commits (170 at the time of writing). A review found no credential in them. Do not
   rewrite history with `git filter-repo`. Everything already pushed is treated as public.
6. **The Dolt host name stays public.** `dolt.<domain>` in `.beads/metadata.json` and `AGENTS.md` is a public DNS name
   for a private address, by design: Dolt has no outside access (no port forward; off-LAN clients come in over
   Tailscale or VPN). The leak guard allowlists it.
7. **Generic private ranges stay.** The docker network subnets (README, REBUILD.md, compose comments) and the Dolt
   grant host pattern in `dolt/init/01-beads-user.sh` identify nothing specific and are needed to recreate the stack
   identically. The leak guard allowlists them; they are not templated.
8. **Agent docs.** The public `AGENTS.md` keeps the platform rules. `homelab-site` gets its own `AGENTS.md` with the
   live-deploy rules, which leave the public one at the cutover.

## Alternatives considered

- **A fresh `homelab` repo, with docker-services archived.** It would re-point everything listed under Context
  while live, and split the history the showcase relies on. A later rename gives the same "v1 Compose -> v2 k3s"
  story inside one history.
- **Keep the runner and deploys in the public repo.** Simpler, but it keeps a self-hosted runner reachable from a
  public repo, guarded only by the fork-approval step.
- **Rewrite history to drop identifying details.** It cannot reach existing clones, forks or cached PR refs, and it
  breaks the deploy checkout's fast-forward deploys. It removes nothing that is not already public.
- **Move the bd config to the private repo.** Agents that clone only the public repo would lose Beads access, to hide
  a name that leaks nothing usable.
- **Template the private ranges.** It costs a NAS copy of the Dolt template (hard rule 8) and makes a rebuild depend
  on more variables, to hide values shared by most home networks.

## Consequences

- Nothing that already references `neybar/docker-services` breaks now. The rename, when it comes, is its own change.
- `ds-nhh.2` creates `neybar/homelab-site`.
- The leak guard (`ds-nhh.5.4`; the scrub was `ds-nhh.5.2`) needs an allowlist: the Dolt host name, the docker subnets and the Dolt grant
  pattern.
- `ds-nhh.5.5`-`ds-nhh.5.7` move the deploy trigger and the runner; until then, the current deploy path and its rules
  in `AGENTS.md` stay as they are.
- Ansible roles must stay instance-free, since they are public; instance values live in `homelab-site`.
- Not decided here: the secrets tooling for `homelab-site` and whether any `/home/jalance` path is allowlisted
  (`ds-nhh.5.8` currently removes them all).
