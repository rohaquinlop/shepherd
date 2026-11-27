#!/usr/bin/env bash
# PreToolUse hook on Edit, Write, MultiEdit, NotebookEdit, and Bash. While a
# diagnosis or a proposal is active in this worktree, keep it read-only:
#   - file edits inside the repo are allowed only in the write-up, in its
#     docs dir (docs/diagnoses/ or docs/proposals/), and in its scratch dir; edits to shepherd
#     state in the git dir are denied even when that dir is outside the repo
#     (a linked worktree)
#   - for each simple command in a Bash call (lib/command.sh; heredoc text and
#     quoted words are not commands), git commands that commit, move, tag,
#     clean, or rewrite work are denied, unless they run on a repo under the
#     scratch dir (the hook's cwd, a leading `cd`, or `git -C`); so are gh
#     writes to a PR, an issue, or the API
# Files outside the repo (memory, temp dirs) and read-only git commands pass.
# Shell redirects and in-place edits (sed -i, >) are not caught: the skill's
# rules cover those.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/command.sh"

command -v jq >/dev/null || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

shepherd_diagnose_active || exit 0

active=$(shepherd_diagnose_file)
root=$(shepherd_root)
writeup=$(jq -r .writeup "$active")
scratch=$(jq -r .scratch "$active")
kind=$(jq -r '.kind // "diagnosis"' "$active")
docs=$(jq -r --arg d "$root/docs/diagnoses" '.docs_dir // $d' "$active")
skill=diagnose label=Diagnosis verb=fix
[[ "$kind" == proposal ]] && { skill=propose label=Proposal verb=implement; }
tool=$(jq -r '.tool_name // empty' <<<"$input")

deny() {
  jq -n --arg r "shepherd $skill: $1 $label '$(jq -r .slug "$active")' is active: $skill only. Put probes in $scratch. To $verb, run \`shepherd $skill end\` and start /shepherd:run $writeup in a new session." \
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

under_scratch() { [[ "$1" == "$scratch_p" || "$1" == "$scratch_p"/* ]]; }
has_dotdot() { [[ "/$1/" == */../* ]]; }

# The dir a cd in the Bash call moves to, or "" when it is unknown. Only the
# call's leading cd may move out of the scratch dir or use `..`: a later one
# may run in a subshell the splitter does not see.
cd_target() {
  local t
  while [[ "${1:-}" == -[LPe@]* ]]; do shift; done
  [[ "${1:-}" == -- ]] && shift
  t=${1:-}
  [[ -z "$t" || "$t" == - || "$t" == '~'* || "$t" == *'$'* ]] && return
  if [[ "$t" != /* ]]; then
    [[ -n "$dir" ]] && { (( leading )) || ! has_dotdot "$t"; } || return
    t="$dir/$t"
  fi
  t=$(cd "$t" 2>/dev/null && pwd -P) || return
  (( leading )) || { under_scratch "$dir" && under_scratch "$t"; } || return
  printf '%s' "$t"
}

# The git command in SHEPHERD_GIT_* runs on a repo whose git dir is under the
# scratch dir. A dir that is not a repo does not count: the scratch dir is in
# the real repo's git dir, so git there acts on the real repo.
in_scratch() {
  local d="$dir" c common
  (( SHEPHERD_GIT_REDIRECT || git_env )) && return 1
  for c in ${SHEPHERD_GIT_DIRS[@]+"${SHEPHERD_GIT_DIRS[@]}"}; do
    if [[ "$c" == /* ]]; then
      d=$c
    else
      [[ -n "$d" ]] && ! has_dotdot "$c" || return 1
      d="$d/$c"
    fi
  done
  [[ -n "$d" ]] && common=$(git -C "$d" rev-parse --git-common-dir 2>/dev/null) && [[ -n "$common" ]] || return 1
  common=$(cd "$d" && cd "$common" && pwd -P) && under_scratch "$common"
}

git_write() {
  local a pos=0
  case "$SHEPHERD_GIT_SUB" in
    commit | switch | checkout | push | merge | rebase | reset | stash | cherry-pick | revert | am | apply | restore | rm | mv | clean | update-ref)
      return 0 ;;
    branch)
      for a in ${SHEPHERD_GIT_ARGS[@]+"${SHEPHERD_GIT_ARGS[@]}"}; do
        [[ "$a" == --delete || "$a" == --move || ( "$a" == -[!-]* && "$a" == *[mMdD]* ) ]] && return 0
      done ;;
    tag)
      for a in ${SHEPHERD_GIT_ARGS[@]+"${SHEPHERD_GIT_ARGS[@]}"}; do
        case "$a" in
          -l | --list | -n* | --contains* | --no-contains* | --points-at* | --merged* | --no-merged* | -v | --verify) return 1 ;;
          -*) ;;
          *) pos=1 ;;
        esac
      done
      (( pos )) && return 0 ;;
    worktree)
      [[ "${SHEPHERD_GIT_ARGS[0]:-}" == add || "${SHEPHERD_GIT_ARGS[0]:-}" == remove ]] && return 0 ;;
  esac
  return 1
}

# A gh command that writes to a PR, an issue, or the API. A graphql call
# counts only with a mutation or an --input file: queries are POSTs too.
gh_write() {
  shepherd_gh_parse "$@"
  case "${SHEPHERD_GH_POS[1]:-} ${SHEPHERD_GH_POS[2]:-}" in
    "pr create" | "pr merge" | "pr edit" | "pr comment" | "pr review" | "issue comment" | "issue close" | "issue edit") return 0 ;;
  esac
  [[ "${SHEPHERD_GH_POS[1]:-}" == api ]] && (( SHEPHERD_GH_WRITE )) || return 1
  [[ " ${SHEPHERD_GH_POS[*]} " == *" graphql "* ]] || return 0
  [[ "$*" == *mutation* || "$*" == *--input* ]]
}

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    target=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    [[ -n "$target" ]] || exit 0
    target=$(physical "$target")
    [[ "$target" == "$(physical "$scratch")"/* ]] && exit 0
    [[ "$target" == "$(physical "$(shepherd_base)")"/* ]] && deny "editing $target is blocked."
    [[ "$target" == "$root"/* ]] || exit 0
    [[ "$target" == "$(physical "$writeup")" ]] && exit 0
    [[ "$target" == "$(physical "$docs")"/* ]] && exit 0
    deny "editing $target is blocked."
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    scratch_p=$(physical "$scratch")
    git_env=0
    [[ "$cmd" == *GIT_DIR* || "$cmd" == *GIT_WORK_TREE* || "$cmd" == *GIT_COMMON_DIR* ]] && git_env=1
    [[ "$cmd" =~ ^[[:space:]]*(cd|pushd)[[:space:]] ]] && leading=1 || leading=0
    dir=$(pwd -P)
    shepherd_split_command "$cmd" --heredoc-data
    for seg in ${SHEPHERD_SEGMENTS[@]+"${SHEPHERD_SEGMENTS[@]}"}; do
      IFS="$SHEPHERD_SEP" read -ra argv <<<"$seg"
      case "${argv[0]##*/}" in
        cd | pushd) dir=$(cd_target "${argv[@]:1}") ;;
        popd) dir="" ;;
        git)
          shepherd_git_parse "${argv[@]}" && git_write && ! in_scratch && deny "this command changes git or PR state." ;;
        gh)
          gh_write "${argv[@]}" && deny "this command changes git or PR state." ;;
      esac
      leading=0
    done
    ;;
esac

exit 0
