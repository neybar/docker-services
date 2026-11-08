#!/bin/bash
#
# Public-repo leak guard: fail if a tracked file holds instance data that is not listed in
# scripts/ci/instance-data-allowlist. This repo is public; see docs/decisions/0001-public-private-split.md.
#
# Flags (PCRE, per tracked file; plugins-local/ is vendored upstream and skipped, as are symlinks and binaries):
#   ipv4  a full address in 10/8, 172.16/12, 192.168/16 or 100.64/10 (CGNAT). The last octet may be % (a MySQL host
#         pattern). CIDR and LIKE forms (x.y.z.0/24, a LIKE pattern) are matched like any address, so each shows up
#         in the allowlist instead of being special-cased here.
#   home  /home/<user>/
#   dolt  a dolt.<name>.<tld> host name. ADR 0001 item 6 keeps the Dolt host name public; matching a generic shape
#         (not the live domain) lets the allowlist say where it may appear and flags it anywhere else.
#
# Allowlist: scripts/ci/instance-data-allowlist, one entry per line: <path-glob> TAB <regex> TAB <reason>. A flagged
# token is allowed when an entry's glob matches its file (bash pattern, * crosses /) and its regex matches the whole
# token. Blank lines and lines starting with # are ignored. A malformed entry or an empty reason is an error. An
# entry that matched nothing is reported as a warning (it is stale: delete it).
#
# The live domain is deliberately not written here or in the allowlist. A check for it needs the value from a secret.
#
# Output names the file, line and flag, never the matched text. No docker, no network. Run by lint.yml; safe by hand.
#
# Usage: ./scripts/ci/test-no-instance-data.sh [repo-dir]   (default: the repo this script lives in)

set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ALLOWLIST="$REPO/scripts/ci/instance-data-allowlist"

IPV4='(?<![\d.])(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.(?:\d{1,3}|%)(?!\d)'
HOMEDIR='/home/[a-z_][a-z0-9_-]*/'
DOLTHOST='\bdolt\.[a-z0-9-]+(?:\.[a-z0-9-]+)+'
PATTERN="(?:$IPV4)|(?:$HOMEDIR)|(?:$DOLTHOST)"

# flag_of <token>: which of the three patterns the token is.
flag_of() {
    if grep -qP -- "^(?:$IPV4)\$" <<<"$1"; then
        echo ipv4
    elif grep -qP -- "^(?:$HOMEDIR)\$" <<<"$1"; then
        echo home
    else
        echo dolt
    fi
}

errors=0
globs=()
regexes=()
used=()
lineno=0
if [[ ! -f "$ALLOWLIST" ]]; then
    echo "ERROR: missing $ALLOWLIST" >&2
    exit 1
fi
while IFS= read -r entry || [[ -n "$entry" ]]; do
    ((lineno++))
    [[ -z "${entry//[[:space:]]/}" || "$entry" == \#* ]] && continue
    tabs="${entry//[^$'\t']/}"
    if [[ ${#tabs} -ne 2 ]]; then
        echo "ERROR: allowlist line $lineno: want <path-glob> TAB <regex> TAB <reason>" >&2
        ((errors++))
        continue
    fi
    g="${entry%%$'\t'*}"
    rest="${entry#*$'\t'}"
    re="${rest%%$'\t'*}"
    why="${rest#*$'\t'}"
    if [[ -z "$g" || -z "$re" || -z "${why//[[:space:]]/}" ]]; then
        echo "ERROR: allowlist line $lineno: empty glob, regex or reason" >&2
        ((errors++))
        continue
    fi
    grep -qP -- "$re" <<<"" 2>/dev/null
    if [[ $? -eq 2 ]]; then
        echo "ERROR: allowlist line $lineno: regex does not compile" >&2
        ((errors++))
        continue
    fi
    globs+=("$g")
    regexes+=("$re")
    used+=("$lineno:0")
done <"$ALLOWLIST"

files=()
while IFS= read -r -d '' f; do
    [[ "$f" == plugins-local/* || -L "$REPO/$f" || ! -f "$REPO/$f" ]] && continue
    files+=("$f")
done < <(git -C "$REPO" ls-files -z)

hits=0
if [[ ${#files[@]} -gt 0 ]]; then
    while IFS= read -r -d '' file && IFS= read -r rest; do
        line="${rest%%:*}"
        token="${rest#*:}"
        allowed=0
        for i in "${!globs[@]}"; do
            # shellcheck disable=SC2053  # the glob is meant to be a pattern
            [[ "$file" == ${globs[i]} ]] || continue
            if grep -qP -- "^(?:${regexes[i]})\$" <<<"$token"; then
                allowed=1
                used[i]="${used[i]%%:*}:1"
                break
            fi
        done
        if [[ $allowed -eq 0 ]]; then
            echo "LEAK: $file:$line: $(flag_of "$token") (not in scripts/ci/instance-data-allowlist)"
            ((hits++))
        fi
    done < <(cd "$REPO" && printf '%s\0' "${files[@]}" | xargs -0 grep -HnoIPZ -- "$PATTERN")
fi

for u in "${used[@]}"; do
    [[ "${u#*:}" == 1 ]] || echo "WARN: allowlist line ${u%%:*} matched nothing; delete it if the data is gone" >&2
done

if [[ $hits -gt 0 || $errors -gt 0 ]]; then
    echo "FAIL: $hits unlisted hit(s), $errors allowlist error(s)"
    exit 1
fi
echo "OK: no unlisted instance data in tracked files"
