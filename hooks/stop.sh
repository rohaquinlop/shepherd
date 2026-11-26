#!/usr/bin/env bash
# Stop hook. While shepherd is in an active phase, block the turn from ending
# and say what is left, so the loop runs to a real stopping point without the
# user nudging it. Waiting phases (reviewer, CI, hosted review, the user, done) let the
# turn end: a background command or the user wakes the session again.
#
# Blocks at most SHEPHERD_MAX_STOP_BLOCKS times in a row. Any `shepherd set`
# resets the counter, so a stuck loop ends instead of spinning.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fleet.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

if lead=$(fleet_lead_record); then
  phase=$(jq -r .lead.phase "$lead")
  if shepherd_in_list "$phase" "$SHEPHERD_LEAD_ACTIVE_PHASES" \
    && (( $(jq -r '.lead.stop_blocks // 0' "$lead") < SHEPHERD_MAX_STOP_BLOCKS )); then
    jq '.lead.stop_blocks = ((.lead.stop_blocks // 0) + 1)' "$lead" >"$lead.tmp" && mv "$lead.tmp" "$lead"
    case "$phase" in
      dispatching) next="run \`shepherd fleet next\`, then start \`shepherd fleet wait\` in the background and set \`fleet lead waiting_fleet\`" ;;
      triage) next="handle every changed slice (settle or ask its question, start unblocked slices, report stalls), then wait again" ;;
      verifying) next="finish the goal review and settle its findings, then set \`fleet lead done\`" ;;
    esac
    reason="shepherd lead phase is '$phase'; the fleet is not at a stopping point. Next: $next. If you need the user, run \`shepherd fleet lead waiting_user\` and ask one question."
    jq -n --arg r "$reason" '{decision: "block", reason: $r}'
    exit 0
  fi
fi

shepherd_is_active || exit 0

phase=$(shepherd_get phase)
shepherd_in_list "$phase" "$SHEPHERD_ACTIVE_PHASES" || exit 0

blocks=$(shepherd_get stop_blocks)
(( ${blocks:-0} >= SHEPHERD_MAX_STOP_BLOCKS )) && exit 0
shepherd_state_apply '.stop_blocks = ((.stop_blocks // 0) + 1)'

case "$phase" in
  study) next="finish the brief and the plan, then implement (or, if the task is complex, run the plan design review, then implement if the review is clean and every design choice is settled; otherwise ask one question on the unsettled choice)" ;;
  implement) next="finish the change, run the targeted checks, commit, then run the review gate" ;;
  review) next="triage the reviewer's findings, fix and commit, then re-review within budget, run the verify call when the budget is spent, or clear the tree" ;;
  push) next="push the cleared commit, then start the CI watch in the background and set phase=waiting_ci" ;;
  triage) next="answer or fix every open comment, then push or move to waiting_review / done" ;;
esac

reason="shepherd phase is '$phase'; the loop is not at a stopping point. Next: $next. If you need the user, set phase=waiting_user and ask one question. If the work is complete, set phase=done."

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
