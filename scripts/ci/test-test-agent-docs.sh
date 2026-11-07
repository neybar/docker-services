#!/bin/bash
#
# Self-test for test-agent-docs.sh: builds throwaway git repos and checks that the nested-file checks pass on a
# correct set and fail on each kind of breakage. Run by lint.yml; no docker, no network.
#
# Usage: scripts/ci/test-test-agent-docs.sh

# shellcheck disable=SC2016  # fixture docs hold literal backticks, not expansions
set -uo pipefail

checker=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-agent-docs.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0

# new_repo <name>: a minimal valid repo (root set plus nested sub/) at $tmp/<name>; cd into it.
new_repo() {
    local d=$tmp/$1
    mkdir -p "$d/sub" && cd "$d" || exit 2
    git init -q . && git config user.email t@example.invalid && git config user.name t
    printf '# Root\n\nSee `README.md`.\n\n## Beads in this repo\n\n<!-- BEGIN BEADS X -->\nx\n<!-- END BEADS X -->\n' > AGENTS.md
    printf '@AGENTS.md\n' > CLAUDE.md
    ln -s AGENTS.md GEMINI.md
    echo hi > README.md
    printf '# Sub\n\nSee `sub/notes.md`.\n' > sub/AGENTS.md
    printf '@AGENTS.md\n' > sub/CLAUDE.md
    ln -s AGENTS.md sub/GEMINI.md
    echo n > sub/notes.md
}

# expect <pass|fail> <label> [pattern]: run the checker in the current repo (after git add -A) and compare; a fail
# case must also print a FAIL line matching pattern, so it fails for the intended reason.
expect() {
    local want=$1 label=$2 pat=${3:-} out rc
    git add -A
    out=$("$checker" 2>&1); rc=$?
    if { [[ $want == pass ]] && (( rc == 0 )); } || { [[ $want == fail ]] && (( rc == 1 )) && grep -q "^FAIL: .*$pat" <<<"$out"; }; then
        echo "ok:   $label (exit $rc)"
    else
        echo "FAIL: $label: wanted $want, got exit $rc"; echo "$out" | sed 's/^/      /'; fails=$((fails + 1))
    fi
}

new_repo good;           expect pass "correct nested set passes"
new_repo noclaude;       rm sub/CLAUDE.md;                          expect fail "nested AGENTS.md without CLAUDE.md fails" "CLAUDE.md is missing"
new_repo noimport;       echo 'hello' > sub/CLAUDE.md;              expect fail "nested CLAUDE.md without @AGENTS.md fails" "CLAUDE.md is missing"
new_repo bigclaude;      { echo '@AGENTS.md'; head -c 2100 /dev/zero | tr '\0' x; echo; } > sub/CLAUDE.md
                                                                    expect fail "nested CLAUDE.md over 2048 bytes fails" "2048"
new_repo nogemini;       rm sub/GEMINI.md;                          expect fail "missing nested GEMINI.md fails" "not a symlink"
new_repo wronggemini;    rm sub/GEMINI.md; ln -s CLAUDE.md sub/GEMINI.md
                                                                    expect fail "GEMINI.md symlink to the wrong file fails" "not a symlink"
new_repo plaingemini;    rm sub/GEMINI.md; cp sub/AGENTS.md sub/GEMINI.md
                                                                    expect fail "GEMINI.md regular file (not a symlink) fails" "not a symlink"
new_repo bigchain;       { cat sub/AGENTS.md; head -c 29000 /dev/zero | tr '\0' x; echo; } > sub/a && mv sub/a sub/AGENTS.md
                                                                    expect fail "chain over 28672 bytes fails" "28672"
new_repo badpath;        echo 'See `sub/missing.md`.' >> sub/AGENTS.md
                                                                    expect fail "bad backticked path in nested doc fails" "missing.md"
new_repo deep;           mkdir -p sub/deep; cp -a sub/AGENTS.md sub/CLAUDE.md sub/GEMINI.md sub/deep/
                                                                    expect pass "two-level nested set passes"
new_repo deepbad;        mkdir -p sub/deep; cp -a sub/AGENTS.md sub/GEMINI.md sub/deep/
                                                                    expect fail "second-level nested dir without CLAUDE.md fails" "CLAUDE.md is missing"

if (( fails )); then echo "$fails self-test case(s) failed"; exit 1; fi
echo "all test-agent-docs self-tests passed"
