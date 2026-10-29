#!/usr/bin/env bash
# PreToolUse hook on Edit, Write, MultiEdit, NotebookEdit, and Bash. While a
# diagnosis is active in this worktree, keep it a diagnosis:
#   - file edits inside the repo are allowed only in the write-up, in
#     docs/diagnoses/, and in the diagnosis scratch dir
#   - git commands that commit, move, or rewrite work are denied
# Files outside the repo (memory, temp dirs) and read-only git commands pass.
# Shell redirects and in-place edits (sed -i, >) are not caught: the skill's
# rules cover those.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

shepherd_diagnose_active || exit 0

active=$(shepherd_diagnose_file)
root=$(shepherd_root)
writeup=$(jq -r .writeup "$active")
scratch=$(jq -r .scratch "$active")
tool=$(jq -r '.tool_name // empty' <<<"$input")

deny() {
  jq -n --arg r "shepherd diagnose: $1 Diagnosis '$(jq -r .slug "$active")' is active: diagnose only. Put probes in $scratch. To fix, run \`shepherd diagnose end\` and start /shepherd:run $writeup in a new session." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Physical path of a file that may not exist yet: resolve the nearest
# existing ancestor, so /tmp vs /private/tmp style links compare equal.
physical() {
  local path="$1" rest=""
  [[ "$path" == /* ]] || path="$PWD/$path"
  while [[ ! -d "$path" && "$path" != "/" ]]; do
    rest="/$(basename "$path")$rest"
    path=$(dirname "$path")
  done
  printf '%s%s' "$(cd "$path" && pwd -P)" "$rest"
}

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    target=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    [[ -n "$target" ]] || exit 0
    target=$(physical "$target")
    [[ "$target" == "$root"/* ]] || exit 0
    [[ "$target" == "$(physical "$writeup")" ]] && exit 0
    [[ "$target" == "$root/docs/diagnoses/"* ]] && exit 0
    [[ "$target" == "$(physical "$scratch")"/* ]] && exit 0
    deny "editing $target is blocked."
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    git_re='(^|[;&|(])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?(commit|switch|checkout|push|merge|rebase|reset|stash|cherry-pick|revert|am|apply|restore|rm|mv|branch[[:space:]]+-[mMdD])([[:space:]]|$)'
    gh_re='(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|merge|edit|comment|review)([[:space:]]|$)'
    if [[ "$cmd" =~ $git_re || "$cmd" =~ $gh_re ]]; then
      deny "this command changes git or PR state."
    fi
    ;;
esac

exit 0
