# plugins-local

Local Traefik plugins, loaded via Traefik's `experimental.localPlugins` so Traefik does not download plugins from GitHub at startup.

## crowdsec-bouncer-traefik-plugin

- Purpose: CrowdSec bouncer middleware for Traefik.
- Upstream: https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
- Pinned tag: v1.7.1
- Commit SHA: bc83e9d0924b9fefcaed5beea880ab18b9f58764
- Vendored: 2026-10-19 (source tarball from the tag, top-level directory stripped)
- Location: `src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/`
- Trimmed to what Traefik loads at runtime: `bouncer.go`, `version.go`, `pkg/`, `vendor/`, `go.mod`, `go.sum`,
  `.traefik.yml`, `.assets/`, `ban.html`, `captcha.html`, plus `LICENSE` and upstream `README.md`.
  Removed: `examples/`, `tests/`, `.github/`, all `*_test.go`, `docker-compose*.yml`, `Makefile`, `renovate.json`,
  `.golangci.yml`, `acquis.yaml`, `.gitignore`. Those are upstream dev/test/demo files this stack never runs, and
  their shell scripts fail ShellCheck. One of them is a real upstream bug: `examples/tls-auth/gencerts.sh` redirects to an
  unset `${stdout}`.

## Bump procedure

1. Pick a release at least 14 days old.
2. Replace the directory contents with that tag's tarball (top-level directory stripped), then apply the same trim
   as above. Check that nothing new outside that list is needed at runtime.
3. Update this README (tag, commit SHA, vendored date).
4. Restart Traefik: `docker compose up -d traefik`.
5. Run `./scripts/validate-traefik.sh` and `./scripts/validate-waf.sh`.
