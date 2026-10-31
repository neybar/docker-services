#!/bin/bash
#
# Decide whether .github/workflows/integration.yml runs a PR on the self-hosted runner, and which checks.
# Pure function of its inputs (no git, no network), so scripts/ci/test-integration-plan.sh can test it.
#
# Usage: integration-plan.sh < changed-files      (one path per line, renames as delete + add)
#   EVENT_ACTION           pull_request_target action: opened, synchronize, reopened, labeled
#   HEAD_REPO, BASE_REPO   owner/name of the PR's head and base repos (they differ for a fork)
#   AUTHOR, HEAD_REF       PR author login and head branch
#   OWNER                  repository owner: the trusted author, and the only one whose label counts
#   HAS_LABEL              "true" if the PR carries the `integration` label
#   LABEL_ADDED, SENDER    for EVENT_ACTION=labeled: the label just added, and who added it
#
# Prints run=true|false, checks=<space-separated>, reason=<text> (GITHUB_OUTPUT format). See docs/DEPLOY.md.

set -euo pipefail

LABEL=integration
# Run order. integration-run.sh accepts exactly these names.
ALL_CHECKS=(compose-config traefik waf task-scheduler dolt)

out() {
    printf 'run=%s\nchecks=%s\nreason=%s\n' "$1" "$2" "$3"
    exit 0
}
skip() { out false "" "$1"; }

# Hard gates. The workflow repeats the fork check in the runner job's `if:`.
[[ -n "${HEAD_REPO:-}" && "$HEAD_REPO" == "${BASE_REPO:-}" ]] \
    || skip "fork PR (${HEAD_REPO:-deleted repo}): never runs on the self-hosted runner"
[[ "${AUTHOR:-}" == "$OWNER" || "${HEAD_REF:-}" == cursor/* || "${HEAD_REF:-}" == claude/* ]] \
    || skip "author '${AUTHOR:-}' is not $OWNER and branch '${HEAD_REF:-}' is not cursor/* or claude/*"

labeled_now=false
if [[ "${EVENT_ACTION:-}" == labeled ]]; then
    # Any other label is a no-op, so labelling a PR does not re-run it.
    [[ "${LABEL_ADDED:-}" == "$LABEL" ]] || skip "label '${LABEL_ADDED:-}' added; only '$LABEL' triggers a run"
    [[ "${SENDER:-}" == "$OWNER" ]] || skip "'$LABEL' added by '${SENDER:-}', not $OWNER"
    labeled_now=true
fi

declare -A want=()
sensitive=""
while IFS= read -r f; do
    case "$f" in
        # What runs on the runner: label-only, so the owner reads it first.
        .github/*|scripts/ci/*) sensitive="$f" ;;
        docker-compose.yml) want[compose-config]=1 want[traefik]=1 want[waf]=1 ;;
        env.example|scripts/deploy.sh|scripts/compose.sh) want[compose-config]=1 ;;
        traefik-rules/*|crowdsec-config/*|plugins-local/*) want[traefik]=1 want[waf]=1 ;;
        # Shared by every validate script, deploy.sh and scripts/compose.sh (host-addrs.sh)
        scripts/lib/*) want[compose-config]=1 want[traefik]=1 want[waf]=1 want[dolt]=1 ;;
        scripts/validate-traefik.sh) want[traefik]=1 ;;
        scripts/validate-waf.sh) want[waf]=1 ;;
        task-scheduler/*) want[task-scheduler]=1 ;;
        dolt/*|scripts/dolt-*|scripts/validate-dolt.sh) want[dolt]=1 ;;
    esac
done

# Only the labeled event itself counts: a later push to the PR needs the label removed and re-added.
if [[ -n "$sensitive" && "$labeled_now" != true ]]; then
    skip "changes $sensitive: runs only when $OWNER adds the '$LABEL' label"
fi

checks=()
for c in "${ALL_CHECKS[@]}"; do
    if [[ -n "${want[$c]:-}" ]]; then checks+=("$c"); fi
done

if ((${#checks[@]} == 0)); then
    [[ "$labeled_now" == true || "${HAS_LABEL:-}" == true ]] || skip "no stack-affecting paths changed"
    out true "${ALL_CHECKS[*]}" "'$LABEL' label, no stack-affecting paths: all checks"
fi
if [[ "$labeled_now" == true || "${HAS_LABEL:-}" == true ]]; then
    out true "${checks[*]}" "'$LABEL' label"
fi
out true "${checks[*]}" "stack-affecting paths changed"
