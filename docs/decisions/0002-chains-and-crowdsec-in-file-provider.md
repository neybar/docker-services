# 0002: Every router uses a chain; `crowdsec@file` lives in the file provider

- **Status:** Accepted
- **Date:** 2026-10-20
- **Links:** PR #27 (CrowdSec WAF); `docs/CROWDSEC.md` ("Why the middleware is in the file provider");
  `AGENTS.md` hard rule 5; `traefik-rules/AGENTS.md`; `REBUILD.md` §7 (CrowdSec, item 4)

## Context

Every web service sits behind Traefik, with a CrowdSec bouncer (bans and AppSec WAF) and Authelia in front of it. A
router that names no middleware bypasses both. The bouncer also has to exist as a middleware before any router can
use it.

Traefik's docker provider skips containers that are not `healthy`, `traefik` itself included
(`docs/CROWDSEC.md`, citing `keepContainer` in Traefik v3.6). A middleware defined as a label on the traefik container
therefore did not exist until its first healthcheck passed, and every chained router answered 404 in the meantime.
`docs/CROWDSEC.md` records the measurement (probe every 0.25s x 120 around `docker compose restart traefik`):

| Variant | Result |
|---|---|
| labels, before `start_interval` | 16x404 + 7x000 |
| labels + `start_interval: 1s` | 7x404 + 8x000 |
| `crowdsec@file` | 0x404, 7x000 |

## Decision

1. Every HTTP router uses one of `chain-authelia@file` (the default), `chain-no-auth@file` or `chain-basic-auth@file`.
   Each chain starts with `crowdsec@file` (`traefik-rules/middleware-chains.yml`), so the WAF runs before
   authentication. `http-catchall` (redirect only, no backend) is the one intended exception. Never remove
   `crowdsec@file` from a chain.
2. `crowdsec@file` is defined in `traefik-rules/crowdsec.yml`, not as a compose label, so it exists as soon as
   Traefik loads its file config.

## Alternatives considered

- **Define the middleware as a label** (the first implementation, per the measurements above). Rejected on the
  404 window. `start_interval: 1s` shortened it (16 to 7 404s) but did not remove it.
- **Add the bouncer per router instead of through chains.** Not recorded as evaluated; the repo records only the
  chain design. A per-router list would make "forgot the WAF" a per-service mistake rather than a single-file one.

## Consequences

- A new service needs only a `chain-*@file` label (README "Adding a service").
- A Traefik restart costs about 2s of connection refused and no 404s (`REBUILD.md` §7).
- Routers in `traefik-rules/` need a chain too. One bypass is known and open: `dsm-photo-rtr` (Beads `ds-o9h`).
  TCP passthrough routers cannot take an HTTP middleware (Beads `ds-0lu`).
- `traefik-rules/` is not watched, so a rules change goes live only on a Traefik restart (`scripts/deploy.sh` does
  it on merge; `docs/DEPLOY.md`).

## Update 2026-11-08

`chain-basic-auth` (and its `middlewares-basic-auth`) was removed as unused (Beads ds-2xi): no router used it and the
passwords file it pointed at was never mounted. Decision 1 now reads `chain-authelia@file` or `chain-no-auth@file`;
the rest of the decision is unchanged.
