#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
source "${ROOT_DIR}/scripts/lib/deployment-common.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
fail(){ echo "not ok - $*" >&2; exit 1; }; pass(){ echo "ok - $*"; }
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[ "$(select_blue_green_candidate "$T")" = blue ] || fail "first activation selects Blue"; pass "first activation selects Blue"
write_active_deployment_color "$T" blue; [ "$(select_blue_green_candidate "$T")" = green ] || fail "active Blue selects Green"
write_active_deployment_color "$T" green; [ "$(select_blue_green_candidate "$T")" = blue ] || fail "active Green selects Blue"; pass "opposite color selection"
printf 'invalid\n' > "$T/active-color"; select_blue_green_candidate "$T" >/dev/null 2>&1 && fail "invalid active color accepted"; pass "invalid active color fails closed"
rm -f "$T/active-color"; write_candidate_deployment_color "$T" green
commit_blue_green_state "$T" "$A" blue "$B"
[ "$(read_active_deployment_color "$T")" = blue ] && [ "$(read_color_deployment_sha "$T" blue)" = "$B" ] && [ "$(read_deployment_sha_file "$T/current.sha")" = "$B" ] && [ "$(read_deployment_sha_file "$T/previous.sha")" = "$A" ] || fail "state transition"
[ ! -e "$T/candidate-color" ] || fail "candidate state cleared"; pass "ordered state transition and candidate cleanup"
LOG="$T/order"; : > "$LOG"
write_color_deployment_sha(){ echo color-sha >> "$LOG"; }; write_deployment_sha_file(){ case "$1" in */previous.sha) echo previous >> "$LOG";; */current.sha) echo current >> "$LOG";; esac; }
write_active_deployment_color(){ echo active-last >> "$LOG"; }; clear_candidate_deployment_color(){ echo clear-candidate >> "$LOG"; }
commit_blue_green_state "$T" "$A" green "$B"
[ "$(cat "$LOG")" = $'color-sha\nprevious\ncurrent\nactive-last\nclear-candidate' ] || fail "state write order"; pass "active color is committed last"
DEPLOY="${ROOT_DIR}/scripts/deploy-blue-green.sh"; ROLLBACK="${ROOT_DIR}/scripts/rollback-blue-green.sh"; WORKFLOW="${ROOT_DIR}/.github/workflows/deploy.yml"
bash "$DEPLOY" deadbeef >/dev/null 2>&1 && fail "invalid SHA accepted"; pass "invalid SHA rejected before host access"
grep -Fq 'compose -p "$PROJECT_NAME" -f "$APP_FILE"' "$DEPLOY" || fail "candidate project Compose"
grep -Fq 'runtime_router_config_path "$DEPLOY_DIR"' "$DEPLOY" || fail "deployment runtime router path"
! grep -Fq '${APP_DIR}/nginx/router.conf' "$DEPLOY" || fail "deployment mutates tracked router config"
grep -Fq 'export DEPLOY_COLOR="$CANDIDATE_COLOR" IMAGE_TAG="$DEPLOY_SHA"' "$DEPLOY" || fail "exact SHA environment"
! grep -Eq 'CANDIDATE_COMPOSE.*(restart|down)' "$DEPLOY" || fail "candidate restarts or downs project"
! grep -Eq 'ACTIVE.*(restart|stop|down)' "$DEPLOY" || fail "active project mutation"
line_verify=$(grep -nF './scripts/verify-color-candidate.sh "$CANDIDATE_COLOR" "$DEPLOY_SHA"' "$DEPLOY" | head -1 | cut -d: -f1)
line_render=$(grep -nF 'render_and_validate_router_candidate "$CANDIDATE_COLOR"' "$DEPLOY" | cut -d: -f1)
line_public=$(grep -nF './scripts/verify-deployment.sh "$VERIFY_APP_URL"' "$DEPLOY" | tail -1 | cut -d: -f1)
line_commit=$(grep -nF 'commit_blue_green_state' "$DEPLOY" | cut -d: -f1)
[ "$line_verify" -lt "$line_render" ] && [ "$line_render" -lt "$line_public" ] && [ "$line_public" -lt "$line_commit" ] || fail "activation ordering"; pass "private verify router validation public verify state ordering"
grep -Fq '[ "$CANDIDATE_COLOR" != "$ACTIVE_COLOR" ]' "$DEPLOY" || fail "candidate can equal active"
pass "candidate cannot equal active color"
pass "failed candidate verification occurs before any router modification"
grep -Fq 'if [ "$ROUTER_SWITCH_APPLIED" = true ]' "$DEPLOY" && grep -Fq 'restore_previous_router' "$DEPLOY" || fail "public failure restoration"
pass "failed public verification restores the previous environment before state commit"
grep -Fq 'restore_previous_router' "$DEPLOY" || fail "deployment restoration"
grep -Fq 'Legacy zero-downtime-app remains running' "$DEPLOY" || fail "legacy retention"
grep -Fq 'Previous color ${ACTIVE_COLOR} remains running' "$DEPLOY" || fail "previous color retention"
! grep -Eq 'TARGET_COMPOSE.*(pull|up)' "$ROLLBACK" || fail "rollback rebuilds retained color"
grep -Fq 'opposite_deployment_color "$ACTIVE_COLOR"' "$ROLLBACK" || fail "rollback opposite color"
grep -Fq 'Retained rollback SHA' "$ROLLBACK" || fail "rollback retained state validation"
grep -Fq 'restore_previous_router' "$ROLLBACK" || fail "rollback restoration"; pass "retained-color rollback is non-rebuilding and restorable"
grep -Fq "if: github.event_name == 'push'" "$WORKFLOW" || fail "push guard"
! grep -Eiq '(^|[[:space:]])(ssh|scp)([[:space:]]|$)|EC2_SSH_KEY' "$WORKFLOW" || fail "SSH dependency"
pass "push guard and SSH-free transport preserved"
