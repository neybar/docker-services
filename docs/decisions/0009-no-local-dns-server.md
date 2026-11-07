# 0009: No local DNS server; the resolved stub listener stays on

- **Status:** Accepted
- **Date:** 2026-11-06
- **Links:** PR #44 (Beads `ds-vsj`; removed Pi-hole); PR #32 (Pi-hole bound to the LAN address); Beads memory
  `host-dns-on-orcrist-tailscale-manages-dns-through`; `REBUILD.md` §2 ("Host DNS"); `AGENTS.md` ("Host DNS")

## Context

Tailscale manages the host's DNS through `systemd-resolved`, so resolved's stub listener (`:53` on the loopback
addresses) must stay enabled. A Pi-hole container wanted `:53` on all addresses. Per the Beads memory, with
`DNSStubListener=no` (set because Pi-hole owned `0.0.0.0:53`) local lookups failed. On 2026-10-22 the host went back
to the default resolved config and Pi-hole was bound to the LAN address only (PR #32), which made it the one other
service needing a host address (ADR 0004).

## Decision

1. NextDNS serves live DNS. There is no local DNS server in the stack, and Pi-hole is retired (PR #44).
2. `/etc/systemd/resolved.conf` stays at the Ubuntu defaults, stub listener on.
3. Nothing in compose may publish `:53`.

## Alternatives considered

- **Keep Pi-hole.** PR #44 removed it as "a cold standby nobody used, and the only other service that needed a host
  IP", which could not take `0.0.0.0:53` while the stub must stay on.
- **Turn the stub listener off.** Tried; local lookups failed (above).
- **Pi-hole on the LAN address only.** Done in PR #32 as an interim fix, then superseded by this decision.

Why NextDNS was chosen over other upstream resolvers is not recorded in the repo or Beads.

## Consequences

- Names such as the Dolt host are public DNS records for private addresses (`dolt/README.md`), not local overrides.
- The DDNS record for the home address is managed on the gateway, not in this stack (`REBUILD.md` §1).
- `PIHOLE_PWD` is still in the live `.env`; `ds-nhh.3` calls it "probably stale".
