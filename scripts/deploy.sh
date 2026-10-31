#!/bin/bash
#
# Deploy master to the running stack on this host (orcrist).
# Run by .github/workflows/deploy.yml on the self-hosted runner; also safe to run by hand.
#
# Usage: ./scripts/deploy.sh
#   DEPLOY_DIR  checkout to deploy into (default /home/jalance/Projects/docker-services)
#   GITHUB_SHA  commit to deploy (set by Actions); defaults to the tip of master
#
# Fast-forwards the checkout and runs `docker compose up -d --build --remove-orphans`, then restarts traefik
# if traefik-rules/ changed since it started (Traefik does not watch it).
# Before touching containers: derives HOST_IP/TAILSCALE_IP (scripts/lib/host-addrs.sh) and refuses to deploy if
# Dolt's live config on the NAS differs from the templates in dolt/ (scripts/lib/dolt-nas.sh).
# Never pulls images (upgrades are a deliberate, separate step) and never resets on failure.
# See docs/DEPLOY.md.

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/home/jalance/Projects/docker-services}"
REPO_URL="https://github.com/neybar/docker-services.git"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cd "$DEPLOY_DIR"

branch=$(git symbolic-ref --short -q HEAD || true)
[[ "$branch" == "master" ]] || die "$DEPLOY_DIR is on '${branch:-detached HEAD}', not master"

# Untracked files are fine (.env and service data are gitignored); tracked edits are not.
if ! git diff --quiet || ! git diff --cached --quiet; then
    git status --short --untracked-files=no >&2
    die "tracked files in $DEPLOY_DIR have local modifications; commit or discard them first"
fi

old=$(git rev-parse HEAD)

# HTTPS so this works without SSH keys (the repo is public).
git fetch --quiet "$REPO_URL" "+refs/heads/master:refs/remotes/origin/master"

target=$(git rev-parse --verify "${GITHUB_SHA:-origin/master}^{commit}") \
    || die "commit ${GITHUB_SHA:-origin/master} not found after fetch"
git merge-base --is-ancestor "$target" origin/master \
    || die "$target is not on master; refusing to deploy it"

if [[ "$target" != "$old" ]] && git merge-base --is-ancestor "$target" "$old"; then
    echo "HEAD ($old) already contains $target; a newer commit is deployed. Nothing to do."
    exit 0
fi

git merge --ff-only --quiet "$target" \
    || die "cannot fast-forward $old to $target; local master has diverged, fix by hand"
new=$(git rev-parse HEAD)

# Preflight, from the new commit's helpers. A failure here changes no container, so it skips the rollback advice:
# fix the cause and rerun (the checkout is already at the new commit, so the rerun reconciles).
# HOST_IP and TAILSCALE_IP are derived from the host, not read from .env.
# shellcheck source=lib/host-addrs.sh
source scripts/lib/host-addrs.sh
host_addrs_export "$DEPLOY_DIR" \
    || die "cannot derive HOST_IP/TAILSCALE_IP (above); nothing was deployed ($DEPLOY_DIR is at ${new:0:7})"
echo "==> HOST_IP=$HOST_IP TAILSCALE_IP=$TAILSCALE_IP (derived from the host)"

# Dolt's live config on the NAS is copied from dolt/ by hand; deploying against a stale copy has broken Dolt before.
# shellcheck source=lib/dolt-nas.sh
source scripts/lib/dolt-nas.sh
if ! drift=$(dolt_nas_drift "$DEPLOY_DIR"); then
    echo "$drift" >&2
    die "Dolt NAS config differs from the templates in dolt/ (above); nothing was deployed ($DEPLOY_DIR is at ${new:0:7}). Copy, then rerun ./scripts/deploy.sh"
fi

on_exit() {
    local rc=$?
    ((rc == 0)) && return
    cat >&2 <<EOF

DEPLOY FAILED (exit $rc). $DEPLOY_DIR was fast-forwarded ${old:0:7} -> ${new:0:7} and left there.
Commits in this deploy:
$(git log --oneline "$old..$new")

To roll back, revert on master through a PR; merging it redeploys:
  git switch -c revert-deploy origin/master
  git revert --no-edit -m 1 <merge-commit>    # once per PR merge commit above
See docs/DEPLOY.md for rolling back by hand.
EOF
}
trap on_exit EXIT

echo "==> Deploying ${old:0:7} -> ${new:0:7}"
if [[ "$old" != "$new" ]]; then
    git log --oneline "$old..$new"
    echo
    git diff --stat "$old" "$new"
else
    echo "(no new commits; reconciling containers with the current compose file)"
fi

[[ -d traefik-rules ]] || die "traefik-rules/ is missing; Traefik would start without its chains"

echo "==> Validating compose file"
docker compose config --quiet

echo "==> docker compose up -d --build --remove-orphans"
docker compose up -d --build --remove-orphans

# Traefik does not watch ./traefik-rules (see the traefik service in docker-compose.yml), and `up -d` does not recreate it
# when only the rules changed. Restart it if anything in the directory (files, or the directory itself for adds/removes)
# is newer than its last start. This compares against what Traefik loaded, not the deployed range, so rules left behind by
# a failed deploy or committed without a restart are applied too.
traefik_id=$(docker compose ps -q traefik)
if [[ -n "$traefik_id" ]]; then
    started=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$traefik_id")" +%s)
    rules_mtime=$(find traefik-rules -printf '%T@\n' | sort -n | tail -1)
    if ((${rules_mtime%.*} >= started)); then
        echo "==> traefik-rules/ changed since traefik started: docker compose restart traefik"
        docker compose restart traefik
    fi
fi

echo "==> docker compose ps"
docker compose ps

echo "==> Deployed $new"
