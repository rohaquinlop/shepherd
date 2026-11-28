#!/usr/bin/env bash
# PreToolUse hook on Bash. On a branch with shepherd state, for each simple
# command in the call (see lib/command.sh):
#   - deny `gh pr merge` and `gh api` merge writes: shepherd never merges
#   - deny force pushes and remote deletes: they discard what reviewers already read
#   - deny `git config` writes of core.hooksPath or extensions.worktreeConfig,
#     removal or rename of the core or extensions section, and
#     rm/mv/cp/ln/chmod/unlink of a path in a git dir's shepherd/ (branch
#     state, the gate dir; not shepherd/_fleet/) or of config.worktree, or any
#     of them run from inside such a dir (the hook's cwd, or a `cd` to it
#     earlier in the call): they turn the git gate off
#   - deny a command with a bare `push` word and a `--no-verify`,
#     `core.hooksPath`, `--git-dir`, or `--work-tree` word, or a call with such
#     a command that names GIT_CONFIG*, GIT_DIR, GIT_COMMON_DIR, or
#     GIT_WORK_TREE: they can skip the git pre-push gate (hooks/git-pre-push.sh).
#     It needs no `git` word, so `$g push` and `$(command -v git) push` count
#   - deny `git push` unless the worktree is clean and HEAD's tree is the tree
#     the review gate cleared (see `shepherd clear`)
# Every other command, and every branch without state, passes through. A call
# whose text names none of push, merge, config, shepherd, or _githooks, and has
# no `{...}` (a brace word can spell them), run outside the shepherd dir, exits
# before any git command.
# Without jq it cannot read the call, so on a branch with state (read from the
# hook's own cwd) it denies any call that names a push or a merge.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/command.sh"

input=$(cat)

if ! command -v jq >/dev/null; then
  text=${input//\\\"/}
  [[ "$text" == *'"command"'* ]] || exit 0
  text=${text#*\"command\"}; text=${text#*\"}; text=${text%%\"*}
  [[ "$text" == *push* || "$text" == *merge* ]] || exit 0
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
DELETE_REASON="never delete a shepherd branch on the remote. It holds the PR head reviewers read."
GATE_REASON="never change or remove the git pre-push gate or shepherd state (core.hooksPath, extensions.worktreeConfig, shepherd/ in the git dir) on a shepherd branch. Ask the user to do it."
DEEP_REASON="this command nests shells or substitutions too deep, or expands braces too far, to read, and it may run a push or a merge. Run the push as a plain command."
VERIFY_REASON="never skip the git pre-push gate (--no-verify, core.hooksPath, GIT_CONFIG*, GIT_DIR, --git-dir, --work-tree). Clear the tree with the review gate, then push."

# Merge words anywhere in the command, not only after a `gh` word, so
# `$(command -v gh) pr merge` and `find -exec gh pr merge` count: no git-level
# gate stops a merge.
is_merge() {
  local a k merge_path=0 api=0
  shepherd_gh_parse "$@"
  for (( k = 0; k < ${#SHEPHERD_GH_POS[@]}; k++ )); do
    [[ "${SHEPHERD_GH_POS[k]}" == pr && "${SHEPHERD_GH_POS[k+1]:-}" == merge ]] && return 0
    [[ "${SHEPHERD_GH_POS[k]}" == api ]] && api=1
  done
  (( api )) || return 1
  for a in "$@"; do
    [[ "$a" == *mergePullRequest* ]] && return 0
    [[ "${a%%\?*}" =~ (^|/)pulls/[^/]+/merge/?$ ]] && merge_path=1
  done
  (( merge_path && SHEPHERD_GH_WRITE ))
}

# Reasons to deny the push in SHEPHERD_GIT_ARGS / SHEPHERD_GIT_CONFIG, or none.
push_denial() {
  local a cfg flags
  shopt -u nocasematch
  for cfg in ${SHEPHERD_GIT_CONFIG[@]+"${SHEPHERD_GIT_CONFIG[@]}"}; do
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"${cfg%%=*}")" == core.hookspath ]] && { echo "$VERIFY_REASON"; return; }
  done
  for a in ${SHEPHERD_GIT_ARGS[@]+"${SHEPHERD_GIT_ARGS[@]}"}; do
    case "$a" in
      --*)
        if (( ${#a} >= 8 )) && [[ "--no-verify" == "$a"* ]]; then echo "$VERIFY_REASON"; return; fi
        a=${a%%=*}
        if (( ${#a} >= 5 )) && [[ "--force-with-lease" == "$a"* || "--force" == "$a"* ]]; then echo "$FORCE_REASON"; return; fi
        if (( ${#a} >= 4 )) && [[ "--delete" == "$a"* ]]; then echo "$DELETE_REASON"; return; fi ;;
      -?*)
        flags=${a#-}
        flags=${flags%%o*}
        [[ "$flags" == *f* ]] && { echo "$FORCE_REASON"; return; }
        [[ "$flags" == *d* ]] && { echo "$DELETE_REASON"; return; } ;;
      +*) echo "$FORCE_REASON"; return ;;
      :*) echo "$DELETE_REASON"; return ;;
    esac
  done
}

# A write to core.hooksPath or extensions.worktreeConfig, or a removal or
# rename of the core or extensions section, after a `config` word, whatever
# runs it (`$g config`, `$(command -v git) config`). Reads pass. The splitter
# drops quotes, so a redirect word (`2>&1`) is read as a value, not skipped.
is_gate_config_write() {
  local seen=0 pos=0 arg=0 key=0 write=0 read=0 section=0 w
  for w in "$@"; do
    if (( ! seen )); then
      [[ "$w" == config ]] && seen=1
      continue
    fi
    if (( arg )); then
      arg=0
      continue
    fi
    case "$w" in
      -f | --file | --blob | --type | --default | --comment | --value | --url) arg=1 ;;
      --get* | --list | -l) read=1 ;;
      --remove-section | --rename-section) write=1 section=1 ;;
      --unset* | --add | --replace-all) write=1 ;;
      -*) ;;
      *)
        pos=$((pos + 1))
        if (( pos == 1 )); then
          case "$w" in
            get | list) read=1; continue ;;
            unset) write=1; continue ;;
            remove-section | rename-section) write=1 section=1; continue ;;
          esac
        fi
        if (( section )); then
          [[ "$w" == core || "$w" == extensions ]] && key=1
        elif [[ "$w" == *hookspath* || "$w" == *worktreeconfig* ]]; then
          key=1
        elif (( key )); then
          write=1
        fi ;;
    esac
  done
  (( key && write && ! read ))
}

# A path in a git dir's shepherd/ (branch state, the gate dir) or a
# config.worktree. Fleet slice worktrees live under shepherd/_fleet/, so that
# subtree is not state. A leading /shepherd is the tail of a substituted path
# (`$(git rev-parse --git-dir)/shepherd`), since the splitter drops `$(...)`.
# The path is matched after `//`, `/./`, and `x/..` collapse; a leading `..`
# stays, so `/../shepherd` (beside the git dir) is not state.
is_state_path() {
  local IFS=/ part p
  local -a parts kept=()
  read -ra parts <<<"$1"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..)
        if (( ${#kept[@]} )) && [[ "${kept[${#kept[@]}-1]}" != .. ]]; then
          unset "kept[${#kept[@]}-1]"
        else
          kept+=(..)
        fi ;;
      *) kept+=("$part") ;;
    esac
  done
  p="${kept[*]}"
  [[ "$1" == /* ]] && p=/$p
  [[ ( "$p" == */_fleet/* || "$p" == */_fleet ) && "$p" != *..* ]] && return 1
  [[ "$p" == *_githooks* || "$p" == config.worktree || "$p" == */config.worktree \
    || "$p" == /shepherd || "$p" == /shepherd/* \
    || "$p" == .git/shepherd || "$p" == .git/shepherd/* || "$p" == */.git/shepherd || "$p" == */.git/shepherd/* \
    || "$p" == */worktrees/*/shepherd || "$p" == */worktrees/*/shepherd/* ]]
}

shopt -s nocasematch
is_state_path "$PWD" && in_state=1 || in_state=0
(( in_state )) || [[ "$cmd" == *push* || "$cmd" == *merge* || "$cmd" == *config* || "$cmd" == *shepherd* || "$cmd" == *_githooks* || "$cmd" == *'{'*'}'* ]] || exit 0
shopt -u nocasematch
shepherd_is_active || exit 0
shepherd_split_command "$cmd"
push=0 merge=0 bypass=0 push_word=0 reason=""
shopt -s nocasematch
for seg in ${SHEPHERD_SEGMENTS[@]+"${SHEPHERD_SEGMENTS[@]}"}; do
  IFS="$SHEPHERD_SEP" read -ra argv <<<"$seg"
  if [[ "$SHEPHERD_SEP$seg$SHEPHERD_SEP" == *"${SHEPHERD_SEP}push$SHEPHERD_SEP"* ]]; then
    push_word=1
    for w in "${argv[@]}"; do
      [[ "$w" == --no-v* || "$w" == *hookspath* || "$w" == --git-dir* || "$w" == --work-tree* ]] && bypass=1
    done
  fi
  case "${argv[0]##*/}" in
    cd | pushd)
      is_state_path "${argv[1]:-}" && in_state=1 ;;
    rm | mv | ln | chmod | unlink | cp)
      (( in_state )) && reason=${reason:-$GATE_REASON}
      for w in "${argv[@]:1}"; do
        is_state_path "$w" && reason=${reason:-$GATE_REASON}
      done ;;
  esac
  if is_merge "${argv[@]}"; then
    merge=1
  elif shepherd_git_parse "${argv[@]}"; then
    case "$SHEPHERD_GIT_SUB" in
      push)
        push=1
        [[ -n "$reason" ]] || reason=$(push_denial) ;;
    esac
  fi
  is_gate_config_write "${argv[@]}" && reason=${reason:-$GATE_REASON}
done
(( push_word )) && [[ "$cmd" == *git_config* || "$cmd" == *git_dir* || "$cmd" == *git_common_dir* || "$cmd" == *git_work_tree* ]] && bypass=1
(( SHEPHERD_SPLIT_TRUNCATED )) && [[ "$cmd" == *push* || "$cmd" == *merge* || "$cmd" == *'{'* ]] && deep=1 || deep=0
shopt -u nocasematch

(( push || merge || bypass || deep )) || [[ -n "$reason" ]] || exit 0
(( bypass )) && [[ -z "$reason" ]] && reason=$VERIFY_REASON
(( deep )) && [[ -z "$reason" ]] && reason=$DEEP_REASON

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
