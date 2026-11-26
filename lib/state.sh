#!/usr/bin/env bash
# Shared state helpers for the shepherd hooks and the shepherd CLI.
# Sourced, never executed.
#
# State lives in the worktree's git dir (`git rev-parse --git-dir`)/shepherd/,
# outside the work tree: Claude Code (seen in 2.1.328) diffs every work-tree
# file a Bash command changes, git-ignored or not, but not files under .git/.
# The per-worktree git dir keeps parallel sessions in different worktrees
# apart, even two on a detached HEAD.
#
# Per branch, under shepherd/<branch>/:
#   brief.md      task contract: scope, success criteria, constraints
#   decisions.md  append-only log of non-obvious decisions and review records
#   state.json    machine state the hooks read: phase, PR, review budget, cleared tree
#
# A diagnosis is per worktree, not per branch, under shepherd/_diagnose/:
#   active.json   slug, write-up path, scratch dir; its presence turns on the edit guard
#   scratch/<slug>/  the only place repro scripts and probes may be written
#
# Older versions kept all of this in <worktree>/.claude/shepherd/; the path
# helpers move it on first use.

SHEPHERD_ACTIVE_PHASES="study implement review push triage"
SHEPHERD_WAIT_PHASES="waiting_reviewer waiting_ci waiting_review waiting_user done"
SHEPHERD_MAX_STOP_BLOCKS=3

shepherd_root() { git rev-parse --show-toplevel 2>/dev/null; }

shepherd_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

shepherd_common_base() {
  local gitdir
  gitdir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ -n "$gitdir" ]] || return 1
  printf '%s/shepherd' "$gitdir"
}

shepherd_base() {
  local gitdir
  gitdir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  [[ -n "$gitdir" ]] || return 1
  printf '%s/shepherd' "$gitdir"
}

# Rewrite a path field that points into the legacy dir. Writes the file
# directly, not through shepherd_set: a move is not progress, so updated_at
# and stop_blocks stay as they were.
shepherd_repoint() {
  local file="$1" key="$2" from="$3/" to="$4/" tmp
  [[ -f "$file" ]] || return 0
  jq -e --arg k "$key" --arg from "$from" '(.[$k] // "") | startswith($from)' "$file" >/dev/null || return 0
  tmp="$file.tmp.$$"
  jq --arg k "$key" --arg from "$from" --arg to "$to" '.[$k] = $to + (.[$k] | ltrimstr($from))' "$file" >"$tmp" \
    && mv "$tmp" "$file"
}

# mkdir is atomic, so one process wins. A loser waits for the winner, so it
# returns only after the move and then reads the moved state. A lock whose pid
# is gone is stale (killed mid-move) and is taken over. No trap: this runs in
# sourced code and would replace the caller's traps.
shepherd_lock() {
  local lock="$1" pid _
  for _ in {1..50}; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock/pid"
      return 0
    fi
    pid=$(cat "$lock/pid" 2>/dev/null)
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      echo "shepherd: removing stale lock $lock (pid $pid is gone)" >&2
      rm -rf "$lock"
      continue
    fi
    sleep 0.1
  done
  if [[ -z "$(cat "$lock/pid" 2>/dev/null)" ]]; then
    echo "shepherd: removing stale lock $lock (no pid after 5s)" >&2
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null && printf '%s\n' "$$" >"$lock/pid" && return 0
  fi
  echo "shepherd: lock $lock is still held; state in .claude/shepherd/ not moved yet" >&2
  return 1
}

shepherd_migrate_legacy() {
  local base="$1" root legacy lock entry target
  root=$(shepherd_root) || return 0
  legacy="$root/.claude/shepherd"
  [[ -d "$legacy" ]] || return 0
  lock="$base.migrate.lock"
  shepherd_lock "$lock" || return 0
  if [[ ! -d "$legacy" ]]; then
    rm -rf "$lock"
    return 0
  fi
  if [[ ! -e "$base" ]]; then
    mv "$legacy" "$base"
  else
    for entry in "$legacy"/* "$legacy"/.[!.]* "$legacy"/..?*; do
      [[ -e "$entry" ]] || continue
      target="$base/${entry##*/}"
      if [[ -e "$target" ]]; then
        [[ -e "$target.legacy" ]] && target="$target.legacy.$$" || target="$target.legacy"
        echo "shepherd: kept $base/${entry##*/}; old copy moved to $target" >&2
      fi
      mv "$entry" "$target"
    done
    rmdir "$legacy" 2>/dev/null
  fi
  for entry in "$base"/*/state.json; do
    shepherd_repoint "$entry" bundle_path "$legacy" "$base"
  done
  shepherd_repoint "$base/_diagnose/active.json" scratch "$legacy" "$base"
  rm -rf "$lock"
}

shepherd_dir() {
  local base branch
  base=$(shepherd_base) || return 1
  branch=$(shepherd_branch) || return 1
  [[ -n "$branch" ]] || return 1
  shepherd_migrate_legacy "$base"
  printf '%s/%s' "$base" "${branch//\//__}"
}

shepherd_state_file() {
  local dir
  dir=$(shepherd_dir) || return 1
  printf '%s/state.json' "$dir"
}

shepherd_is_active() {
  local file
  file=$(shepherd_state_file) || return 1
  [[ -f "$file" ]]
}

shepherd_diagnose_file() {
  local base
  base=$(shepherd_base) || return 1
  shepherd_migrate_legacy "$base"
  printf '%s/_diagnose/active.json' "$base"
}

shepherd_diagnose_active() {
  local file
  file=$(shepherd_diagnose_file) || return 1
  [[ -f "$file" ]]
}

shepherd_get() {
  jq -r --arg k "$1" '.[$k] // empty' "$(shepherd_state_file)"
}

shepherd_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Low-level write: applies a jq filter to state.json atomically.
shepherd_state_apply() {
  local file tmp
  file=$(shepherd_state_file) || return 1
  tmp="$file.tmp.$$"
  jq "$@" "$file" >"$tmp" && mv "$tmp" "$file"
}

# shepherd_set key=value (string) or key:=json (number, bool, null, array).
# Any agent-driven write means progress, so it resets the stop-hook counter.
shepherd_set() {
  local pair key value args=() filter='.'
  local i=0
  for pair in "$@"; do
    if [[ "$pair" == *":="* ]]; then
      key=${pair%%:=*}
      value=${pair#*:=}
      args+=(--argjson "v$i" "$value")
    elif [[ "$pair" == *"="* ]]; then
      key=${pair%%=*}
      value=${pair#*=}
      args+=(--arg "v$i" "$value")
    else
      echo "shepherd: expected key=value or key:=json, got '$pair'" >&2
      return 2
    fi
    filter+=" | .[\"$key\"] = \$v$i"
    i=$((i + 1))
  done
  filter+=' | .stop_blocks = 0 | .updated_at = $now'
  shepherd_state_apply --arg now "$(shepherd_now)" "${args[@]}" "$filter"
}

shepherd_config() {
  local root file
  root=$(shepherd_root) || return 1
  file="$root/.claude/shepherd.json"
  [[ -f "$file" ]] || return 0
  jq -r --arg k "$1" '.[$k] // empty | if type == "array" then .[] else . end' "$file"
}

shepherd_target_branch() {
  local target
  target=$(shepherd_config target_branch)
  if [[ -z "$target" ]]; then
    target=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    target=${target#origin/}
  fi
  printf '%s' "${target:-main}"
}

shepherd_in_list() {
  local needle="$1" item
  for item in $2; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}
