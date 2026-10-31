#!/bin/bash
#
# Table tests for scripts/ci/integration-plan.sh. Run by lint.yml; also safe to run by hand (no git, no network).
#
# Usage: ./scripts/ci/test-integration-plan.sh

set -uo pipefail

PLAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/integration-plan.sh"
ALL="compose-config traefik waf task-scheduler dolt"
pass=0
fail=0

# check <name> <want run> <want checks> <changed files, newline-separated> [VAR=value ...]
# Defaults: a same-repo PR by the owner from a claude/ branch, opened, without the label.
check() {
    local name=$1 want_run=$2 want_checks=$3 files=$4 got
    shift 4
    got=$(env -i PATH="$PATH" \
        EVENT_ACTION=opened HEAD_REPO=neybar/docker-services BASE_REPO=neybar/docker-services \
        AUTHOR=neybar HEAD_REF=claude/x OWNER=neybar HAS_LABEL=false LABEL_ADDED= SENDER=neybar \
        "$@" "$PLAN" <<<"$files")
    local run checks
    run=$(sed -n 's/^run=//p' <<<"$got")
    checks=$(sed -n 's/^checks=//p' <<<"$got")
    if [[ "$run" == "$want_run" && "$checks" == "$want_checks" ]]; then
        ((pass++))
    else
        ((fail++))
        echo "FAIL: $name"
        echo "  want run=$want_run checks=$want_checks"
        echo "  got  $(tr '\n' ' ' <<<"$got")"
    fi
}

# Eligibility
check "fork, stack path"              false "" "docker-compose.yml" HEAD_REPO=evil/docker-services
check "fork, labeled by owner"        false "" "docker-compose.yml" HEAD_REPO=evil/docker-services EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check "deleted head repo"             false "" "docker-compose.yml" HEAD_REPO=
check "owner, any branch"             true  "compose-config traefik waf" "docker-compose.yml" HEAD_REF=feature/x
check "cursor/ branch, other author"  true  "traefik waf" "traefik-rules/crowdsec.yml" AUTHOR=someone HEAD_REF=cursor/x
check "claude/ branch, other author"  true  "traefik waf" "traefik-rules/crowdsec.yml" AUTHOR=someone HEAD_REF=claude/x
check "other author and branch"       false "" "traefik-rules/crowdsec.yml" 'AUTHOR=dependabot[bot]' HEAD_REF=dependabot/x
check "other author, labeled"         false "" "traefik-rules/crowdsec.yml" AUTHOR=someone HEAD_REF=feature/x EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check "branch prefix only at start"   false "" "traefik-rules/crowdsec.yml" AUTHOR=someone HEAD_REF=x/claude/y

# Path selection
check "docs only"                     false "" $'README.md\ndocs/DEPLOY.md\nCLAUDE.md'
check "no files"                      false "" ""
check "compose"                       true  "compose-config traefik waf" "docker-compose.yml"
check "env.example"                   true  "compose-config" "env.example"
check "deploy.sh"                     true  "compose-config" "scripts/deploy.sh"
check "crowdsec-config"               true  "traefik waf" "crowdsec-config/acquis.d/appsec.yaml"
check "plugins-local"                 true  "traefik waf" "plugins-local/src/x/go.mod"
check "compose.sh"                    true  "compose-config" "scripts/compose.sh"
check "scripts/lib"                   true  "compose-config traefik waf dolt" "scripts/lib/validate-common.sh"
check "scripts/lib host-addrs"        true  "compose-config traefik waf dolt" "scripts/lib/host-addrs.sh"
check "validate-traefik.sh only"      true  "traefik" "scripts/validate-traefik.sh"
check "validate-waf.sh only"          true  "waf" "scripts/validate-waf.sh"
check "validate-dolt.sh only"         true  "dolt" "scripts/validate-dolt.sh"
check "task-scheduler"                true  "task-scheduler" "task-scheduler/scripts/dolt-certs.sh"
check "dolt dir"                      true  "dolt" "dolt/servercfg/config.yaml"
check "dolt script"                   true  "dolt" "scripts/dolt-add-db.sh"
check "mixed, ordered, deduplicated"  true  "$ALL" $'dolt/x\ntask-scheduler/Dockerfile\ntraefik-rules/a.yml\ndocker-compose.yml\nREADME.md\ncrowdsec-config/b'
check "lookalike paths"               false "" $'docs/docker-compose.yml\nold/traefik-rules/x\nscripts/dolt\nkometa/config.yml.example'

# Label
check "label on push, stack path"     true  "traefik waf" "traefik-rules/a.yml" EVENT_ACTION=synchronize HAS_LABEL=true
check "label on push, docs only"      true  "$ALL" "README.md" EVENT_ACTION=synchronize HAS_LABEL=true
check "labeled now, docs only"        true  "$ALL" "README.md" EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check "other label added"             false "" "docker-compose.yml" EVENT_ACTION=labeled LABEL_ADDED=documentation
check "label added by non-owner"      false "" "docker-compose.yml" EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true SENDER=someone

# .github/ and scripts/ci/: only on the owner's labeled event
check ".github, opened"               false "" $'.github/workflows/lint.yml\ndocker-compose.yml'
check ".github, push with label"      false "" $'.github/workflows/lint.yml\ndocker-compose.yml' EVENT_ACTION=synchronize HAS_LABEL=true
check ".github, labeled by owner"     true  "compose-config traefik waf" $'.github/workflows/lint.yml\ndocker-compose.yml' EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check ".github only, labeled"         true  "$ALL" ".github/dependabot.yml" EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check ".github, labeled by non-owner" false "" ".github/workflows/x.yml" EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true SENDER=someone
check "scripts/ci, opened"            false "" "scripts/ci/integration-run.sh"
check "scripts/ci, labeled"           true  "$ALL" "scripts/ci/integration-run.sh" EVENT_ACTION=labeled LABEL_ADDED=integration HAS_LABEL=true
check ".github renamed away"          false "" $'.github/workflows/x.yml\nworkflows/x.yml'

echo "integration-plan: $pass passed, $fail failed"
((fail == 0))
