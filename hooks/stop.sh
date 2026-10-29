#!/usr/bin/env bash
# Stop hook. While shepherd is in an active phase, block the turn from ending
# and say what is left, so the loop runs to a real stopping point without the
# user nudging it. Waiting phases (CI, hosted review, the user, done) let the
# turn end: a background command or the user wakes the session again.
#
# Blocks at most SHEPHERD_MAX_STOP_BLOCKS times in a row. Any `shepherd set`
# resets the counter, so a stuck loop ends instead of spinning.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

shepherd_is_active || exit 0

phase=$(shepherd_get phase)
shepherd_in_list "$phase" "$SHEPHERD_ACTIVE_PHASES" || exit 0

blocks=$(shepherd_get stop_blocks)
(( ${blocks:-0} >= SHEPHERD_MAX_STOP_BLOCKS )) && exit 0
shepherd_state_apply '.stop_blocks = ((.stop_blocks // 0) + 1)'

case "$phase" in
  study) next="finish the brief and the plan, then implement (or ask the one simple/complex question if the task is complex)" ;;
  implement) next="finish the change, run the targeted checks, commit, then run the review gate" ;;
  review) next="triage the reviewer's findings, fix and commit, then re-review within budget or clear the tree" ;;
  push) next="push the cleared commit, then start the CI watch in the background and set phase=waiting_ci" ;;
  triage) next="answer or fix every open comment, then push or move to waiting_review / done" ;;
esac

reason="shepherd phase is '$phase'; the loop is not at a stopping point. Next: $next. If you need the user, set phase=waiting_user and ask one question. If the work is complete, set phase=done."

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
