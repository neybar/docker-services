#!/bin/bash
#
# Deploy master to the running stack on this host (orcrist).
# Run by .github/workflows/deploy.yml on the self-hosted runner; also safe to run by hand.
#
# Usage: ./scripts/deploy.sh
#   DEPLOY_DIR  checkout to deploy into (default /home/jalance/Projects/docker-services)
#   GITHUB_SHA  commit to deploy (set by Actions); defaults to the tip of master
#
# Fast-forwards the checkout and runs `docker compose up -d --build --remove-orphans`.
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

echo "==> Validating compose file"
docker compose config --quiet

# An empty bouncer key fails closed: the plugin rejects it, crowdsec@docker is never built, and every chained router breaks.
grep -Eq '^CROWDSEC_BOUNCER_KEY=.+' "$DEPLOY_DIR/.env" \
    || die "CROWDSEC_BOUNCER_KEY is missing or empty in $DEPLOY_DIR/.env; see REBUILD.md (CrowdSec)"

echo "==> docker compose up -d --build --remove-orphans"
docker compose up -d --build --remove-orphans

echo "==> docker compose ps"
docker compose ps

echo "==> Deployed $new"
