#!/usr/bin/env bash
# SessionStart hook. When a diagnosis is active, or the current branch has
# shepherd state, load it into context, so a new or cleared session resumes
# instead of starting over. Silent otherwise.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

context=""

if shepherd_diagnose_active; then
  writeup=$(jq -r .writeup "$(shepherd_diagnose_file)")
  context="A shepherd diagnosis is active in this worktree (write-up: ${writeup}). Edits outside the write-up and its scratch dir are blocked. Resume it with the shepherd:diagnose skill; read the write-up first.
"
fi

if shepherd_is_active && [[ "$(shepherd_get phase)" != "done" ]]; then
  dir=$(shepherd_dir)
  context+="shepherd is active on this branch (phase: $(shepherd_get phase)). Resume it with the shepherd:run skill before doing anything else on this branch. State dir: ${dir}

## state.json
$(cat "$dir/state.json")

## brief.md
$(cat "$dir/brief.md" 2>/dev/null)

Read ${dir}/decisions.md before you change direction on anything it records."
fi

[[ -n "$context" ]] || exit 0

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
