#!/usr/bin/env bash
# SessionStart hook. When the current branch has shepherd state, load the task
# contract and machine state into context, so a new or cleared session resumes
# the loop instead of starting over. Silent on branches without state.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

shepherd_is_active || exit 0

dir=$(shepherd_dir)
phase=$(shepherd_get phase)
[[ "$phase" == "done" ]] && exit 0

context="shepherd is active on this branch (phase: ${phase}). Resume it with the shepherd:run skill before doing anything else on this branch. State dir: ${dir}

## state.json
$(cat "$dir/state.json")

## brief.md
$(cat "$dir/brief.md" 2>/dev/null)

Read ${dir}/decisions.md before you change direction on anything it records."

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
