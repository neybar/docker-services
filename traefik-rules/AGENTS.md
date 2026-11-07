# traefik-rules/AGENTS.md

Subtree rules for `traefik-rules/` (Traefik file-provider config). Root `AGENTS.md` still applies, in particular hard
rule 5 (chains, `crowdsec@file`) and the Traefik and CrowdSec invariants. Background: `docs/CROWDSEC.md`. Paths here
are repo-root-relative.

- Routers defined here need a `chain-*@file` middleware too (hard rule 5). Known bypass: `dsm-photo-rtr` in
  `traefik-rules/synology.yml` (no chain; Beads `ds-o9h`).
- `crowdsec@file` is defined in `traefik-rules/crowdsec.yml`, not as a compose label, because the docker provider skips
  containers that are not healthy (Traefik included): a label-defined middleware did not exist until the first
  healthcheck passed, and every chained router 404ed (`docs/CROWDSEC.md`, "Why the middleware is in the file
  provider").
- Not watched: a change goes live only on a traefik restart (`deploy.sh` does it on merge; by hand
  `docker compose restart traefik`). The directory is mounted read-only at `/rules` as a directory on purpose (a
  single-file bind mount goes stale when git replaces the file).
- `DISABLE_SCENARIOS` (in compose) is deliberate: `crowdsecurity/crowdsec-appsec-outofband` stays off until CRS is
  tuned (Beads `ds-vhq`), `crowdsecurity/http-crawl-non_statics` would ban our own WAN IP. Details: `docs/CROWDSEC.md`,
  "Rules and scenarios".
- CrowdSec has no Docker API access because the socket proxy cannot scope it below reading every container's env and
  filesystem; socket-proxy `EXEC` stays off (`docs/CROWDSEC.md`, "Authelia logs are not read by CrowdSec").
- The LAN whitelist suppresses bans, not AppSec blocks: probes from this host get 403 (and an alert, no ban).
- After a change: `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh` (live stack, so after the deploy).
