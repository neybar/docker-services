#!/bin/bash
#
# Drift checks for the agent instruction files. Run by lint.yml; safe to run by hand (no docker, no network).
#   a. root AGENTS.md is at most 16 KiB (Codex truncates project docs past project_doc_max_bytes, 32 KiB by default)
#   b. root CLAUDE.md imports @AGENTS.md and is at most 2 KiB; root GEMINI.md resolves to AGENTS.md
#   c. every backticked repo path in every AGENTS.md and CLAUDE.md (root and nested) is tracked in git.
#      Paths in nested docs are repo-root-relative, not relative to the nested doc's directory.
#   d. (root only) the bd-generated BEGIN/END marker pairs are present, paired, and after "## Beads in this repo"
#   e. every nested dir/AGENTS.md has a sibling CLAUDE.md (@AGENTS.md line, at most 2 KiB), a sibling GEMINI.md symlink
#      resolving to it, and root + ancestors + itself total at most 28672 bytes (Codex reads that chain as one budget)
#
# Usage: scripts/ci/test-agent-docs.sh   (from anywhere inside the repo)

set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok() { echo "ok:   $*"; }

# a. size cap
agents_bytes=$(wc -c < AGENTS.md)
if (( agents_bytes <= 16384 )); then ok "AGENTS.md is $agents_bytes bytes (<= 16384)"
else fail "AGENTS.md is $agents_bytes bytes (> 16384): move detail to the human docs"; fi

# b. CLAUDE.md and GEMINI.md point at AGENTS.md
claude_bytes=$(wc -c < CLAUDE.md)
if grep -qx '@AGENTS.md' CLAUDE.md; then ok "CLAUDE.md imports @AGENTS.md"
else fail "CLAUDE.md has no '@AGENTS.md' line"; fi
if (( claude_bytes <= 2048 )); then ok "CLAUDE.md is $claude_bytes bytes (<= 2048)"
else fail "CLAUDE.md is $claude_bytes bytes (> 2048): agent rules belong in AGENTS.md"; fi
if [[ -L GEMINI.md && "$(readlink -f GEMINI.md)" == "$(readlink -f AGENTS.md)" ]]; then ok "GEMINI.md -> AGENTS.md"
else fail "GEMINI.md is not a symlink to AGENTS.md"; fi

# c. backticked repo paths. A token counts as a repo path if it has no spaces or placeholder/shell characters and
# either contains a '/' with a first component that is tracked at the top level (must be tracked at that path), or is
# a bare file name with a doc/config/script extension (must be tracked somewhere, e.g. `deploy.sh`). Placeholders
# (<x>, $VAR, *, ~, absolute host paths) and gitignored paths (e.g. `.beads/issues.jsonl`) are skipped.
top_level=$(git ls-files | cut -d/ -f1 | sort -u)
skip_re='[[:space:]<>$*~{}:@=]'
skip_re='[[:space:]<>$*~{}:@=]'
checked=0
# shellcheck disable=SC2016  # the grep pattern holds literal backticks, not an expansion
check_paths() {
    local doc=$1 tok path pathspec
    while IFS= read -r tok; do
        [[ -z "$tok" || "$tok" =~ $skip_re || "$tok" == /* ]] && continue
        path=${tok#./}
        path=${path%/}
        if [[ "$path" == */* ]]; then
            grep -qxF -- "${path%%/*}" <<<"$top_level" || continue
            pathspec=$path
        else
            [[ "$path" =~ \.(md|ya?ml|sh|json|toml|mdc)$ ]] || continue
            pathspec=":(glob)**/$path"
        fi
        git check-ignore -q --no-index -- "$path" && continue
        checked=$((checked + 1))
        [[ -n "$(git ls-files -- "$pathspec")" ]] || fail "$doc names \`$tok\`, which is not tracked in the repo"
    done < <(grep -o '`[^`]*`' "$doc" | tr -d '`')
}

# every tracked AGENTS.md, nested ones included, and its sibling CLAUDE.md
mapfile -t nested < <(git ls-files -- '*/AGENTS.md')
docs=(AGENTS.md CLAUDE.md)
for n in "${nested[@]}"; do docs+=("$n" "$(dirname "$n")/CLAUDE.md"); done
for doc in "${docs[@]}"; do
    [[ -f "$doc" ]] && check_paths "$doc"
done
ok "checked $checked backticked repo paths in ${#docs[@]} doc(s)"

# d. generated bd blocks: paired, and after the hand-written Beads section
beads_line=$(grep -n -m1 '^## Beads in this repo$' AGENTS.md | cut -d: -f1)
if [[ -z "$beads_line" ]]; then
    fail "AGENTS.md has no '## Beads in this repo' section"
    beads_line=0
fi
pairs=0 open_line=0
while IFS=: read -r n text; do
    if [[ "$text" == "<!-- BEGIN BEADS"* ]]; then
        (( open_line )) && fail "AGENTS.md:$n: BEGIN marker inside the block opened at line $open_line"
        (( n > beads_line )) || fail "AGENTS.md:$n: generated block starts before '## Beads in this repo'"
        open_line=$n
    else
        (( open_line )) || fail "AGENTS.md:$n: END marker without a BEGIN"
        (( open_line )) && pairs=$((pairs + 1))
        open_line=0
    fi
done < <(grep -n -E '^<!-- (BEGIN|END) BEADS' AGENTS.md)
(( open_line )) && fail "AGENTS.md:$open_line: BEGIN marker never closed"
if (( pairs >= 1 )); then ok "$pairs generated bd block(s), paired"
else fail "AGENTS.md has no generated bd blocks (rerun bd setup codex / bd setup claude)"; fi

# e. nested AGENTS.md files: CLAUDE.md and GEMINI.md siblings, and the Codex chain budget
for n in "${nested[@]}"; do
    dir=$(dirname "$n")
    if [[ -f "$dir/CLAUDE.md" ]] && grep -qx '@AGENTS.md' "$dir/CLAUDE.md"; then ok "$dir/CLAUDE.md imports @AGENTS.md"
    else fail "$dir/CLAUDE.md is missing or has no '@AGENTS.md' line"; fi
    if [[ -f "$dir/CLAUDE.md" ]]; then
        cb=$(wc -c < "$dir/CLAUDE.md")
        (( cb <= 2048 )) || fail "$dir/CLAUDE.md is $cb bytes (> 2048): agent rules belong in AGENTS.md"
    fi
    if [[ -L "$dir/GEMINI.md" && "$(readlink -f "$dir/GEMINI.md")" == "$(readlink -f "$n")" ]]; then ok "$dir/GEMINI.md -> AGENTS.md"
    else fail "$dir/GEMINI.md is not a symlink to $n"; fi
    # chain: root AGENTS.md plus every AGENTS.md from the top down to this directory
    chain=$agents_bytes parent=$dir
    while [[ "$parent" != . ]]; do
        [[ -f "$parent/AGENTS.md" ]] && chain=$((chain + $(wc -c < "$parent/AGENTS.md")))
        parent=$(dirname "$parent")
    done
    if (( chain <= 28672 )); then ok "$n chain is $chain bytes (<= 28672)"
    else fail "$n chain (root + ancestors + itself) is $chain bytes (> 28672): Codex would truncate it"; fi
done

if (( fails )); then
    echo "$fails check(s) failed"
    exit 1
fi
echo "all agent-doc checks passed"
