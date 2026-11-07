# 0003: The CrowdSec bouncer fails open; two scenarios stay disabled

- **Status:** Accepted
- **Date:** 2026-10-20
- **Links:** PR #27 (CrowdSec WAF); `docs/CROWDSEC.md` ("Fails open on purpose", "Rules and scenarios"); Beads
  `ds-vhq` (open); `AGENTS.md` ("Traefik and CrowdSec"); `traefik-rules/AGENTS.md`

## Context

CrowdSec runs in front of every chained router (ADR 0002). Authelia is still the authentication layer, so a CrowdSec
outage should not take the stack down. Separately, some CrowdSec scenarios misfire against this stack's own traffic.

## Decision

1. **Fail open.** If the CrowdSec LAPI or AppSec is unreachable, traffic passes (`docs/CROWDSEC.md`):
   `updateMaxFailure=-1` (the default `0` would block all traffic once the LAPI is unreachable in stream mode),
   `streamStartupBlock=false`, and AppSec failure passes. `docs/CROWDSEC.md` records a test: CrowdSec stopped for
   100s, services kept answering, `/.env` was not blocked.
2. **Not everything fails open.** Unreadable request bodies on POST/PUT/PATCH/DELETE block (plugin default, pinned),
   and `httpTimeoutSeconds` stays at the plugin default so a short timeout cannot be used to skip inspection. A wrong
   or unregistered bouncer key is an outage (403 on every chained router), and an empty key fails closed.
3. **Disabled scenarios** (`DISABLE_SCENARIOS` in compose):
   - `crowdsecurity/crowdsec-appsec-outofband`: the OWASP CRS ban scenario. CRS runs out-of-band, alerts only, until
     it is tuned. Re-enabling it, and later `crs-inband`, is Beads `ds-vhq`.
   - `crowdsecurity/http-crawl-non_statics`: one *arr/Organizr page load makes many non-static requests, so it would
     ban the stack's own WAN IP for 4h.

## Alternatives considered

- **Fail closed** (block when CrowdSec is down). Not recorded as evaluated in the repo beyond the reason above
  (Authelia remains the auth layer). It would make a WAF outage a full outage.
- **Leave all scenarios enabled.** Rejected for `http-crawl-non_statics` on the ban risk; the other base HTTP
  scenarios stay on. For the CRS ban scenario the stated reason is only "off until CRS is tuned".

## Consequences

- Banned IPs pass for about 60s after a Traefik start, until the first stream sync.
- Disabling scenarios taints the `appsec-crs`, `base-http-scenarios` and `traefik` collections, so hub upgrades skip
  them until the scenarios are re-enabled (`docs/CROWDSEC.md`).
- Agents must not re-enable either scenario or add `crs-inband` casually (`AGENTS.md`).
- The key-mismatch outage is detected by `scripts/validate-waf.sh`; rotation is in `REBUILD.md` §7.
