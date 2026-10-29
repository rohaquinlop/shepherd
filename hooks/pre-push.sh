#!/usr/bin/env bash
# PreToolUse hook on Bash. On a branch with shepherd state:
#   - deny `gh pr merge`: shepherd never merges
#   - deny force pushes: they discard what reviewers already read
#   - deny `git push` unless the worktree is clean and HEAD's tree is the tree
#     the review gate cleared (see `shepherd clear`)
# Every other command, and every branch without state, passes through.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

deny() {
  jq -n --arg r "shepherd: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

push_re='(^|[;&|(])[[:space:]]*git[[:space:]]([^;&|]*[[:space:]])?push([[:space:]]|$)'
merge_re='(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
force_re='[[:space:]](-f|--force|--force-with-lease[^[:space:]]*)([[:space:]]|$)'

[[ "$cmd" =~ $push_re || "$cmd" =~ $merge_re ]] || exit 0
shepherd_is_active || exit 0

if [[ "$cmd" =~ $merge_re ]]; then
  deny "never merge a shepherd PR. Set phase=done and hand the PR back to the user."
fi

if [[ "$cmd" =~ $force_re ]]; then
  deny "never force-push a shepherd branch. Push follow-up commits so earlier reviews stay valid."
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  deny "the worktree has uncommitted changes. Commit the exact state you reviewed, then push."
fi

head_tree=$(git rev-parse 'HEAD^{tree}')
cleared_tree=$(shepherd_get cleared_tree)
if [[ "$head_tree" != "$cleared_tree" ]]; then
  deny "HEAD tree $head_tree is not cleared (cleared: ${cleared_tree:-none}). Run the review gate, or record an exempt delta with \`shepherd clear --exempt <class> --reason <why>\`, then push."
fi

exit 0
