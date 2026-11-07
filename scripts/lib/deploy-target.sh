#!/bin/bash
#
# Pick the commit deploy.sh deploys, and refuse anything that is not on master. Source it, do not run it.
#
# Usage: deploy_resolve_target   (run inside the checkout, after origin/master was fetched)
#   Target, first set wins: $DEPLOY_SHA, $GITHUB_SHA, origin/master. DEPLOY_SHA exists for the private deploy
#   workflow, whose GITHUB_SHA is a commit of the private repo and not in this one.
#   Prints the full commit id to stdout and returns 0. Otherwise prints "ERROR: ..." to stderr and returns 1.
#   The `merge-base --is-ancestor <target> origin/master` guard applies to every source, including DEPLOY_SHA.

deploy_resolve_target() {
    local ref="${DEPLOY_SHA:-${GITHUB_SHA:-origin/master}}" target
    target=$(git rev-parse --verify "$ref^{commit}") || {
        echo "ERROR: commit $ref not found after fetch" >&2
        return 1
    }
    git merge-base --is-ancestor "$target" origin/master || {
        echo "ERROR: $target is not on master; refusing to deploy it" >&2
        return 1
    }
    echo "$target"
}
