#!/bin/bash
#
# Run integration checks for a PR head against the live stack on this host (orcrist).
# Run by .github/workflows/integration.yml on the self-hosted runner, always from master's copy of this script.
#
# Usage: HEAD_SHA=<sha> scripts/ci/integration-run.sh <check>...
#   checks      any of: compose-config traefik waf task-scheduler dolt (picked by integration-plan.sh)
#   HEAD_SHA    full SHA of the PR head to test
#   DEPLOY_DIR  live checkout (default /home/jalance/Projects/docker-services); only its .env is read, and it is the lock
#
# Read-only against the stack: no `docker compose up`, no restarts, the deploy checkout is never switched or written.
# The PR head is fetched into a fresh repo in a temp dir. What the PR's own validate scripts do is up to them:
# they run with docker access (= root), which is why integration-plan.sh only lets trusted PRs reach this. See docs/DEPLOY.md.

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/home/jalance/Projects/docker-services}"
REPO_URL="https://github.com/neybar/docker-services.git"
LOCK_WAIT=1800

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "HEAD_SHA must be a full commit SHA"
(($# > 0)) || die "no checks given"
for c in "$@"; do
    case "$c" in
        compose-config|traefik|waf|task-scheduler|dolt) ;;
        *) die "unknown check: $c" ;;
    esac
done
[[ -f "$DEPLOY_DIR/.env" ]] || die "$DEPLOY_DIR/.env not found"

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/integration.XXXXXX")
image="docker-services-ci/task-scheduler:${HEAD_SHA:0:12}"
cleanup() {
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# A fresh repo, not a worktree of the deploy checkout (that would write to its .git). No credentials: the repo is public.
git -C "$work" init -q
git -C "$work" fetch -q --depth 1 --no-tags "$REPO_URL" "$HEAD_SHA"
git -C "$work" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "$(git -C "$work" rev-parse HEAD)" == "$HEAD_SHA" ]] || die "fetched commit is not $HEAD_SHA"
echo "==> Testing $HEAD_SHA in $work"

# The validate scripts and compose read $PROJECT_DIR/.env: link the live one. Compose names the project after the
# directory, so pin it to the live project for `docker compose ps/exec` in validate-waf.sh.
ln -s "$DEPLOY_DIR/.env" "$work/.env"
COMPOSE_PROJECT_NAME=$(basename "$DEPLOY_DIR")
export COMPOSE_PROJECT_NAME

# HOST_IP and TAILSCALE_IP are not in .env: derive them like deploy.sh, with master's helper (this checkout, not the PR's).
# shellcheck source=../lib/host-addrs.sh
source "$(dirname "$(readlink -f "$0")")/../lib/host-addrs.sh"
host_addrs_export "$DEPLOY_DIR" || die "cannot derive HOST_IP/TAILSCALE_IP (above)"

# deploy.yml holds the same lock (flock on the deploy directory) around deploy.sh: never test while a deploy changes the stack.
exec 9<"$DEPLOY_DIR"
echo "==> Waiting for the deploy lock on $DEPLOY_DIR"
flock -w "$LOCK_WAIT" 9 || die "a deploy held the lock for over ${LOCK_WAIT}s"

check_compose_config() { (cd "$work" && docker compose config --quiet); }
check_traefik() { "$work/scripts/validate-traefik.sh"; }
check_waf() { "$work/scripts/validate-waf.sh"; }
# Builds the PR's image under a throwaway tag (removed on exit). The live service builds from the deploy checkout.
check_task_scheduler() { docker build -t "$image" "$work/task-scheduler"; }
check_dolt() {
    if [[ -x "$work/scripts/validate-dolt.sh" ]]; then
        "$work/scripts/validate-dolt.sh"
    else
        echo "::notice::dolt: scripts/validate-dolt.sh does not exist in this PR; skipped"
    fi
}

failed=()
for c in "$@"; do
    echo "::group::$c"
    if "check_${c//-/_}"; then
        echo "::endgroup::"
        echo "PASS: $c"
    else
        rc=$?
        echo "::endgroup::"
        echo "::error::$c failed (exit $rc)"
        failed+=("$c")
    fi
done

if ((${#failed[@]} > 0)); then
    die "failed: ${failed[*]}"
fi
echo "==> All checks passed: $*"
