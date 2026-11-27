#!/usr/bin/env bash
# Git pre-push gate. `shepherd init` copies it, with lib/state.sh, to
# <worktree git dir>/shepherd/_githooks/gate/, and the pre-push stub there
# runs the copy, so a plugin update or move never leaves the stub without a
# gate. Git runs it for every push from this worktree, whatever the command
# shape; `--no-verify` skips it, and the PreToolUse hook denies that. For each
# pushed ref whose branch (the local branch, or the remote branch it updates)
# has shepherd state here:
#   - a delete is rejected: it drops the PR head reviewers read
#   - the pushed commit's tree must be the tree the review gate cleared
#   - the push must fast-forward the remote ref
# Refs of branches without state pass through.
# Args: remote name and URL. stdin: one "<local ref> <local sha> <remote ref> <remote sha>" per line.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

base=$(shepherd_base) || exit 0
current=$(shepherd_branch)
status=0

state_for() {
  local lref="$1" rref="$2" b file
  for b in "${lref#refs/heads/}" "${rref#refs/heads/}"; do
    [[ "$b" == HEAD ]] && b=$current
    [[ "$b" == refs/* || -z "$b" ]] && continue
    file="$(shepherd_branch_dir "$base" "$b")/state.json"
    [[ -f "$file" ]] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

while read -r lref lsha rref rsha; do
  [[ -n "$lref" ]] || continue
  file=$(state_for "$lref" "$rref") || continue
  if [[ "$lsha" =~ ^0+$ ]]; then
    echo "shepherd: never delete $rref; it is a shepherd branch and holds the PR head." >&2
    status=1; continue
  fi
  if ! command -v jq >/dev/null; then
    echo "shepherd: jq is not installed, so the push gate cannot read $file. Install jq, then push." >&2
    status=1; continue
  fi
  tree=$(git rev-parse "$lsha^{tree}")
  cleared=$(jq -r '.cleared_tree // empty' "$file")
  if [[ "$tree" != "$cleared" ]]; then
    echo "shepherd: $lref tree $tree is not cleared (cleared: ${cleared:-none}). Run the review gate, then push." >&2
    status=1; continue
  fi
  if [[ ! "$rsha" =~ ^0+$ ]] && ! git merge-base --is-ancestor "$rsha" "$lsha" 2>/dev/null; then
    echo "shepherd: pushing $lref to $rref does not fast-forward $rsha. Never force-push a shepherd branch; push follow-up commits." >&2
    status=1
  fi
done

exit "$status"
