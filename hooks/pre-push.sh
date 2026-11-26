#!/usr/bin/env bash
# PreToolUse hook on Bash. On a branch with shepherd state, for each simple
# command in the call (see lib/command.sh):
#   - deny `gh pr merge` and `gh api` merge writes: shepherd never merges
#   - deny force pushes: they discard what reviewers already read
#   - deny a command with a bare `push` word and a `--no-verify` or
#     `core.hooksPath` word, or a call with such a command that names
#     GIT_CONFIG*: they can skip the git pre-push gate (hooks/git-pre-push.sh).
#     It needs no `git` word, so `$g push` and `$(command -v git) push` count
#   - deny `git push` unless the worktree is clean and HEAD's tree is the tree
#     the review gate cleared (see `shepherd clear`)
# Every other command, and every branch without state, passes through.
# Without jq it cannot read the call, so on a branch with state (read from the
# hook's own cwd) it denies any call that names a push or a merge.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/command.sh"

input=$(cat)

if ! command -v jq >/dev/null; then
  [[ "$input" == *push* || "$input" == *merge* ]] || exit 0
  shepherd_is_active || exit 0
  echo "shepherd: jq is not installed, so the push gate cannot read this command. Install jq, then retry." >&2
  exit 2
fi

cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

deny() {
  jq -n --arg r "shepherd: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

MERGE_REASON="never merge a shepherd PR. Set phase=done and hand the PR back to the user."
FORCE_REASON="never force-push a shepherd branch. Push follow-up commits so earlier reviews stay valid."
VERIFY_REASON="never skip the git pre-push gate (--no-verify, core.hooksPath). Clear the tree with the review gate, then push."

is_merge() {
  [[ "${1##*/}" == gh ]] || return 1
  [[ "${2:-}" == pr && "${3:-}" == merge ]] && return 0
  [[ "${2:-}" == api ]] || return 1
  local a prev="" method="" fields=0 merge_path=0
  for a in "${@:3}"; do
    case "$prev" in -X | --method) method=$a ;; esac
    case "$a" in
      -X?*) method=${a#-X} ;;
      --method=*) method=${a#--method=} ;;
      -f | -F | --field | --raw-field | --input | -f?* | -F?* | --field=* | --raw-field=* | --input=*) fields=1 ;;
      *mergePullRequest*) return 0 ;;
    esac
    [[ "$a" =~ (^|/)pulls/[^/]+/merge$ ]] && merge_path=1
    prev=$a
  done
  (( merge_path )) || return 1
  case "$method" in
    [Gg][Ee][Tt]) return 1 ;;
    "") (( fields )) ;;
  esac
}

# Reasons to deny the push in SHEPHERD_GIT_ARGS / SHEPHERD_GIT_CONFIG, or none.
push_denial() {
  local a cfg flags
  for cfg in ${SHEPHERD_GIT_CONFIG[@]+"${SHEPHERD_GIT_CONFIG[@]}"}; do
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"${cfg%%=*}")" == core.hookspath ]] && { echo "$VERIFY_REASON"; return; }
  done
  for a in ${SHEPHERD_GIT_ARGS[@]+"${SHEPHERD_GIT_ARGS[@]}"}; do
    case "$a" in
      --*)
        if (( ${#a} >= 8 )) && [[ "--no-verify" == "$a"* ]]; then echo "$VERIFY_REASON"; return; fi
        a=${a%%=*}
        if (( ${#a} >= 5 )) && [[ "--force-with-lease" == "$a"* || "--force" == "$a"* ]]; then echo "$FORCE_REASON"; return; fi ;;
      -?*)
        flags=${a#-}
        flags=${flags%%o*}
        [[ "$flags" == *f* ]] && { echo "$FORCE_REASON"; return; } ;;
      +*) echo "$FORCE_REASON"; return ;;
    esac
  done
}

shepherd_split_command "$cmd"
push=0 merge=0 bypass=0 push_word=0 reason=""
shopt -s nocasematch
for seg in ${SHEPHERD_SEGMENTS[@]+"${SHEPHERD_SEGMENTS[@]}"}; do
  IFS="$SHEPHERD_SEP" read -ra argv <<<"$seg"
  if [[ "$SHEPHERD_SEP$seg$SHEPHERD_SEP" == *"${SHEPHERD_SEP}push$SHEPHERD_SEP"* ]]; then
    push_word=1
    for w in "${argv[@]}"; do
      [[ "$w" == --no-v* || "$w" == *hookspath* ]] && bypass=1
    done
  fi
  if is_merge "${argv[@]}"; then
    merge=1
  elif shepherd_git_parse "${argv[@]}" && [[ "$SHEPHERD_GIT_SUB" == push ]]; then
    push=1
    [[ -n "$reason" ]] || reason=$(push_denial)
  fi
done
(( push_word )) && [[ "$cmd" == *git_config* ]] && bypass=1
shopt -u nocasematch

(( push || merge || bypass )) || exit 0
shepherd_is_active || exit 0
(( bypass )) && [[ -z "$reason" ]] && reason=$VERIFY_REASON

(( merge )) && deny "$MERGE_REASON"
[[ -n "$reason" ]] && deny "$reason"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  deny "the worktree has uncommitted changes. Commit the exact state you reviewed, then push."
fi

head_tree=$(git rev-parse 'HEAD^{tree}')
cleared_tree=$(shepherd_get cleared_tree)
if [[ "$head_tree" != "$cleared_tree" ]]; then
  deny "HEAD tree $head_tree is not cleared (cleared: ${cleared_tree:-none}). Run the review gate, or record an exempt delta with \`shepherd clear --exempt <class> --reason <why>\`, then push."
fi

exit 0
