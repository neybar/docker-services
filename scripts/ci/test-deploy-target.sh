#!/bin/bash
#
# Tests for scripts/lib/deploy-target.sh (deploy.sh's target selection and on-master guard) on a throwaway git repo
# under a temp directory, removed on exit. No docker, no network, no root. Run by lint.yml; safe by hand.
#   - DEPLOY_SHA beats GITHUB_SHA; GITHUB_SHA beats the origin/master default; nothing set = origin/master
#   - a commit not on master is refused whichever variable names it; so is an unknown commit
#   - an empty DEPLOY_SHA counts as unset
#   - deploy.sh still sources the lib, calls the function, and reads DEPLOY_REPO_URL with the public default
#
# Usage: ./scripts/ci/test-deploy-target.sh

# The wiring greps match shell text with fixed strings, so single quotes are intended.
# shellcheck disable=SC2016
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/deploy-target.sh
source "$REPO/scripts/lib/deploy-target.sh"
pass=0
fail=0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ok() {
    if [[ "$2" == 0 ]]; then
        ((pass++))
    else
        ((fail++))
        echo "FAIL: $1"
        if [[ -n "${3:-}" ]]; then while IFS= read -r line; do echo "  $line"; done <<<"$3"; fi
    fi
}

# Fake checkout: master has c1 < c2 < c3 (origin/master = c3); a side branch has "offmaster", which is not on master.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q -b master "$tmp/repo"
cd "$tmp/repo" || exit 1
c=()
for n in 1 2 3; do
    echo "$n" >f
    git add f
    git -c commit.gpgsign=false commit -q -m "c$n"
    c[n]=$(git rev-parse HEAD)
done
git update-ref refs/remotes/origin/master "${c[3]}"
git switch -q -c side "${c[1]}"
echo off >g
git add g
git -c commit.gpgsign=false commit -q -m offmaster
off=$(git rev-parse HEAD)
git switch -q master

# run <name> <want-rc> <want-stdout-or-empty> <want-stderr-substring-or-empty> VAR=val...  (env -i keeps the caller's vars out)
run() {
    local name="$1" want_rc="$2" want_out="$3" want_err="$4" out err rc
    shift 4
    out=$(env -i PATH="$PATH" HOME="$tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$@" \
        bash -c "source '$REPO/scripts/lib/deploy-target.sh'; deploy_resolve_target" 2>"$tmp/err")
    rc=$?
    err=$(<"$tmp/err")
    ok "$name: exit $rc, want $want_rc" "$([[ $rc == "$want_rc" ]] && echo 0 || echo 1)" "$err"
    if [[ -n "$want_out" ]]; then ok "$name: stdout" "$([[ $out == "$want_out" ]] && echo 0 || echo 1)" "got '$out' want '$want_out'"; fi
    if [[ -z "$want_out" && $want_rc != 0 ]]; then ok "$name: no stdout on failure" "$([[ -z $out ]] && echo 0 || echo 1)" "$out"; fi
    if [[ -n "$want_err" ]]; then ok "$name: stderr mentions '$want_err'" "$([[ $err == *"$want_err"* ]] && echo 0 || echo 1)" "$err"; fi
}

run "nothing set = origin/master" 0 "${c[3]}" "" A=1
run "GITHUB_SHA beats origin/master" 0 "${c[2]}" "" GITHUB_SHA="${c[2]}"
run "DEPLOY_SHA beats origin/master" 0 "${c[1]}" "" DEPLOY_SHA="${c[1]}"
run "DEPLOY_SHA beats GITHUB_SHA" 0 "${c[1]}" "" DEPLOY_SHA="${c[1]}" GITHUB_SHA="${c[2]}"
run "empty DEPLOY_SHA falls back to GITHUB_SHA" 0 "${c[2]}" "" DEPLOY_SHA= GITHUB_SHA="${c[2]}"
run "empty both = origin/master" 0 "${c[3]}" "" DEPLOY_SHA= GITHUB_SHA=
run "short DEPLOY_SHA resolves to the full id" 0 "${c[2]}" "" DEPLOY_SHA="${c[2]:0:12}"
run "non-master GITHUB_SHA refused" 1 "" "is not on master" GITHUB_SHA="$off"
run "non-master DEPLOY_SHA refused" 1 "" "is not on master" DEPLOY_SHA="$off"
run "non-master DEPLOY_SHA refused even with a master GITHUB_SHA" 1 "" "is not on master" DEPLOY_SHA="$off" GITHUB_SHA="${c[2]}"
run "master DEPLOY_SHA wins over a non-master GITHUB_SHA" 0 "${c[2]}" "" DEPLOY_SHA="${c[2]}" GITHUB_SHA="$off"
run "unknown DEPLOY_SHA refused" 1 "" "not found after fetch" DEPLOY_SHA=0123456789abcdef0123456789abcdef01234567
run "unknown GITHUB_SHA refused" 1 "" "not found after fetch" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567

# deploy.sh wiring (it is not run here: it needs the live host). Fixed-string greps for shell text, so no expansion.
d="$REPO/scripts/deploy.sh"
grep -qF 'source scripts/lib/deploy-target.sh' "$d"
ok "deploy.sh sources lib/deploy-target.sh" $?
grep -qF 'target=$(deploy_resolve_target)' "$d"
ok "deploy.sh calls deploy_resolve_target" $?
grep -qF 'REPO_URL="${DEPLOY_REPO_URL:-https://github.com/neybar/docker-services.git}"' "$d"
ok "deploy.sh REPO_URL defaults to the public repo" $?
grep -qF 'merge-base --is-ancestor' "$REPO/scripts/lib/deploy-target.sh"
ok "the on-master guard is in the lib" $?
grep -qF 'git fetch --quiet "$REPO_URL" "+refs/heads/master:refs/remotes/origin/master"' "$d"
ok "deploy.sh fetches master by URL (never set-url on origin)" $?
! grep -qE 'remote (set-url|add)|config .*remote\.' "$d"
ok "deploy.sh never rewrites the origin remote" $?

echo "deploy-target: $pass passed, $fail failed"
[[ $fail == 0 ]]
