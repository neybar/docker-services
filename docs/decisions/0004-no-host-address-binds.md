# 0004: No host addresses in compose

- **Status:** Accepted
- **Date:** 2026-11-06
- **Links:** PR #44 (Beads `ds-vsj`); PR #38, PR #32 (what it removed); `AGENTS.md` hard rule 4; `dolt/README.md`
  ("Network"); `REBUILD.md` §7 ("Host addresses")

## Context

Before this change, services that needed a host address got one from `HOST_IP` and `TAILSCALE_IP`. PR #38 derived
them at deploy time (`scripts/lib/host-addrs.sh`) and added a `scripts/compose.sh` wrapper; Dolt published `:3307`
on those addresses, and PR #32 bound Pi-hole's `:53` to `HOST_IP`. Plain `docker compose` stopped working without the
wrapper or shell-profile state.

The recorded cost (commit message of PR #44): the bind address "added nothing on this host and stopped Dolt when
tailscaled was late." PR #38 itself had to add a fallback for a missing Tailscale address (commit `7d1dca0`).

## Decision

1. Compose runs as plain `docker compose <args>` from the checkout root. No wrapper script.
2. Do not bind a port to a host IP (LAN or Tailscale) or require one as a variable. They belong to the host and change
   under it, and a stale one stops the service.
3. Restrict access at the network (no port forward, the tailnet ACL) and in the service (TLS, per-user auth).
   Dolt publishes `:3307` on every host address on this basis.

## Alternatives considered

- **Keep the derived-address wrapper** (PR #38). Replaced by this decision: it needed state outside the repo and
  failed when an address was late or absent.
- **Fixed addresses in `.env`.** The repo's rule is to not require them as variables (they change under the host).
  The LAN address is a DHCP lease; `REBUILD.md` §7 says to keep it reserved on the gateway because a DNS record
  points at it, and that a changed address breaks that record, not the stack.

## Consequences

- `docker compose`, CI, agents and hooks all work without setup. `scripts/compose.sh` is gone;
  `scripts/lib/host-addrs.sh` remains only for test targets in the `validate-*` scripts.
- Pi-hole was removed in the same PR (ADR 0009).
- Exposure of Dolt rests on the router and tailnet ACL being right, not on the bind address
  (`dolt/README.md`, ADR 0008).
- `docs/DEPLOY.md` still tells emergency rollbacks of commits older than `ds-vsj` to use `./scripts/compose.sh`.
