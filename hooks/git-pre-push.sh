#!/usr/bin/env bash
# Git pre-push gate, run by the pre-push stub `shepherd init` writes in
# <worktree git dir>/shepherd/_githooks. Git runs it for every push from this
# worktree, whatever the command shape; only `--no-verify` skips it, and the
# PreToolUse hook denies that. For each pushed ref whose branch (the local
# branch, or the remote branch it updates) has shepherd state here:
#   - the pushed commit's tree must be the tree the review gate cleared
#   - the push must fast-forward the remote ref
# Refs of branches without state, and deletes, pass through.
# Args: remote name and URL. stdin: one "<local ref> <local sha> <remote ref> <remote sha>" per line.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

base=$(shepherd_base) || exit 0
current=$(shepherd_branch)
status=0

state_for() {
  local lref="$1" rref="$2" b
  for b in "${lref#refs/heads/}" "${rref#refs/heads/}"; do
    [[ "$b" == HEAD ]] && b=$current
    [[ "$b" == refs/* || -z "$b" ]] && continue
    [[ -f "$base/${b//\//__}/state.json" ]] && { printf '%s' "$base/${b//\//__}/state.json"; return 0; }
  done
  return 1
}

while read -r lref lsha rref rsha; do
  [[ -n "$lref" && ! "$lsha" =~ ^0+$ ]] || continue
  file=$(state_for "$lref" "$rref") || continue
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
