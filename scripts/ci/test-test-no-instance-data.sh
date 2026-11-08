#!/bin/bash
#
# Self-test for scripts/ci/test-no-instance-data.sh on throwaway git repos under a temp directory, removed on exit.
# No docker, no network. Run by lint.yml; safe by hand.
#   - a clean repo passes; public and documentation addresses (8.8.8.8, 192.0.2.x, 172.32.x, 100.128.x) pass
#   - each flagged class fails: 10/8, 172.16/12, 192.168/16, 100.64/10, a CIDR form, a LIKE form, /home/<user>/, dolt.<host>
#   - an allowlisted hit passes, a second token on the same line does not ride along, a glob that does not match the file fails
#   - plugins-local/ is skipped; a symlink is skipped
#   - allowlist errors fail (no reason, wrong field count, bad regex, missing file); a stale entry only warns
#   - the output names file and line, never the matched text
#
# Addresses are assembled from parts so that this file does not trip the guard it tests.
#
# Usage: ./scripts/ci/test-test-no-instance-data.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/ci/test-no-instance-data.sh"
pass=0
fail=0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

e=.255.1
a=10 b=172.16 c=192.168 d=100.64 u=/home/ n=dolt.

# fresh <name>: empty tracked repo at $tmp/<name> with an empty allowlist; later files are added by put.
fresh() {
    rm -rf "${tmp:?}/$1"
    git init -q "$tmp/$1"
    mkdir -p "$tmp/$1/scripts/ci"
    : >"$tmp/$1/scripts/ci/instance-data-allowlist"
    cur="$tmp/$1"
}
# put <path> <content>
put() {
    mkdir -p "$(dirname "$cur/$1")"
    printf '%s\n' "$2" >"$cur/$1"
}
# allow <glob> <regex> <reason>
allow() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$cur/scripts/ci/instance-data-allowlist"; }

# expect <name> <want-rc> <want-output-substring-or-empty>   (runs the check on $cur)
expect() {
    local name="$1" want="$2" sub="$3" out rc
    git -C "$cur" add -A
    out=$("$CHECK" "$cur" 2>&1)
    rc=$?
    if [[ $rc -ne $want ]]; then
        ((fail++))
        echo "FAIL: $name: rc $rc, want $want"
        while IFS= read -r l; do echo "  $l"; done <<<"$out"
    elif [[ -n "$sub" && "$out" != *"$sub"* ]]; then
        ((fail++))
        echo "FAIL: $name: output lacks '$sub'"
        while IFS= read -r l; do echo "  $l"; done <<<"$out"
    else
        ((pass++))
    fi
    last="$out"
}

fresh clean
put README.md "nothing to see; 8.8.8.8, 192.0.2.10, 172.32.0.1, 100.128.0.1, 10.1.2 and 1.10.0.5"
expect "clean repo and public addresses" 0 "OK"

for case in "10/8:$a.1.2.3" "172.16/12:$b.4.5" "172.31:172.31$e" "192.168/16:$c.1.20" "CGNAT:$d.0.9" "CGNAT top:100.127$e" \
    "CIDR:$c.50.0/24" "LIKE:$c.0.%" "home:${u}someone/x" "dolt host:${n}example.invalid"; do
    fresh "hit"
    put f.txt "x ${case#*:} y"
    expect "flags ${case%%:*}" 1 "LEAK: f.txt:1:"
done

fresh nomatch
put f.txt "x $c.1.20 y"
expect "output omits the matched text" 1 "LEAK"
[[ "$last" != *"$c.1.20"* ]]
if [[ $? -eq 0 ]]; then ((pass++)); else
    ((fail++))
    echo "FAIL: output printed the matched text"
fi

fresh allowed
put f.txt "network $c.90.0 here"
allow "f.txt" '192\.168\.90\.0' "test reason"
expect "allowlisted hit passes" 0 "OK"

fresh sameline
put f.txt "network $c.90.0 and $c.7.7"
allow "f.txt" '192\.168\.90\.0' "test reason"
expect "second token on an allowlisted line fails" 1 "LEAK: f.txt:1:"

fresh partial
put f.txt "$c.90.0"
allow "f.txt" '192\.168\.9' "regex must match the whole token"
expect "regex matches the whole token" 1 "LEAK"

fresh otherfile
put f.txt "$c.90.0"
allow "g.txt" '192\.168\.90\.0' "wrong file"
expect "glob for another file fails" 1 "LEAK"

fresh globdir
put sub/dir/f.txt "path ${u}someone/x"
allow "sub/*" '/home/someon[e]/' "glob crosses /"
expect "glob star crosses directories" 0 "OK"

fresh vendor
put plugins-local/src/x/README.md "vendored $c.1.20 and ${u}someone/x"
put README.md "ok"
expect "plugins-local is skipped" 0 "OK"

fresh vendor2
put plugins-local-not/f.txt "$c.1.20"
expect "only plugins-local/ is skipped" 1 "LEAK: plugins-local-not/f.txt:1:"

fresh link
put real.txt "ok"
ln -s real.txt "$cur/link.txt"
expect "symlink is not scanned twice" 0 "OK"

fresh dupe
put a.txt "$c.1.20"
put b.txt "$c.1.21"
expect "each file is reported" 1 "FAIL: 2 unlisted"

fresh stale
put f.txt "ok"
allow "f.txt" '192\.168\.90\.0' "nothing matches"
expect "stale entry warns, does not fail" 0 "matched nothing"

fresh comments
put f.txt "$c.90.0"
{ echo "# comment"; echo; } >>"$cur/scripts/ci/instance-data-allowlist"
allow "f.txt" '192\.168\.90\.0' "after comments"
expect "comments and blank lines are ignored" 0 "OK"

fresh noreason
put f.txt "$c.90.0"
printf 'f.txt\t192\\.168\\.90\\.0\t\n' >>"$cur/scripts/ci/instance-data-allowlist"
expect "empty reason is an error" 1 "empty glob, regex or reason"

fresh blankreason
put f.txt "$c.90.0"
printf 'f.txt\t192\\.168\\.90\\.0\t   \n' >>"$cur/scripts/ci/instance-data-allowlist"
expect "blank reason is an error" 1 "empty glob, regex or reason"

fresh twofields
put f.txt "ok"
printf 'f.txt\t192\\.168\\.90\\.0\n' >>"$cur/scripts/ci/instance-data-allowlist"
expect "two fields are an error" 1 "want <path-glob>"

fresh fourfields
put f.txt "ok"
printf 'f.txt\tx\tr\textra\n' >>"$cur/scripts/ci/instance-data-allowlist"
expect "extra field is an error" 1 "want <path-glob>"

fresh badre
put f.txt "ok"
allow "f.txt" '(' "unbalanced"
expect "regex that does not compile is an error" 1 "does not compile"

fresh nofile
put f.txt "ok"
rm "$cur/scripts/ci/instance-data-allowlist"
expect "missing allowlist is an error" 1 "missing"

# The real repo passes its own guard.
cur="$REPO"
out=$("$CHECK" 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then ((pass++)); else
    ((fail++))
    echo "FAIL: this repo does not pass its own guard"
    while IFS= read -r l; do echo "  $l"; done <<<"$out"
fi

echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
