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
SHEPHERD_LEAD_ACTIVE_PHASES="dispatching triage verifying"
SHEPHERD_LEAD_WAIT_PHASES="waiting_fleet waiting_user done"

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

# Hooks that run on the client side and do nothing when absent. Each gets a
# stub in the gate dir that runs the repo's own hook (hooks/git-chain.sh).
SHEPHERD_CLIENT_HOOKS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
  prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge post-rewrite
  pre-auto-gc reference-transaction sendemail-validate post-index-change"

shepherd_githooks_dir() {
  local base
  base=$(shepherd_base) || return 1
  printf '%s/_githooks' "$base"
}

shepherd_uninstall_git_gate() {
  local dir
  dir=$(shepherd_githooks_dir) || return 1
  if [[ "$(git config --worktree core.hooksPath 2>/dev/null)" == "$dir" ]]; then
    git config --worktree --unset core.hooksPath
  fi
  rm -rf "$dir"
}

# Point this worktree's core.hooksPath at a gate dir whose pre-push runs
# hooks/git-pre-push.sh, then the repo's own pre-push. The setting is per
# worktree (extensions.worktreeConfig), so other worktrees keep their hooks.
# Skipped, with a warning, when the shared config has core.worktree or
# core.bare=true (git-worktree(1): those must leave the shared config once the
# extension is on), when the extension is off on purpose, or when this
# worktree sets its own core.hooksPath. Reinstalls, so a new plugin path takes.
# `git worktree add` copies config.worktree, so a new worktree may point at
# another worktree's gate dir; that path is replaced with its own.
shepherd_install_git_gate() {
  local root="$1" dir config ext current name skip=""
  config="$(git rev-parse --path-format=absolute --git-common-dir)/config" || return 1
  dir=$(shepherd_githooks_dir) || return 1
  ext=$(git config --file "$config" --type=bool extensions.worktreeConfig)
  current=$(git config --worktree core.hooksPath 2>/dev/null)
  if [[ -n "$(git config --file "$config" core.worktree)" \
    || "$(git config --file "$config" --type=bool core.bare)" == true ]]; then
    skip="core.worktree or core.bare=true is set in $config"
  elif [[ "$ext" == false ]]; then
    skip="extensions.worktreeConfig is false in $config"
  elif [[ -n "$current" && "$current" != */shepherd/_githooks ]]; then
    skip="this worktree sets core.hooksPath=$current"
  fi
  if [[ -n "$skip" ]]; then
    echo "shepherd: $skip; git push gate not installed, the PreToolUse hook still gates pushes" >&2
    return 0
  fi
  [[ -n "$ext" ]] || git config --file "$config" extensions.worktreeConfig true || return 1
  shepherd_uninstall_git_gate
  mkdir -p "$dir" && cp "$root/hooks/git-chain.sh" "$dir/chain" || return 1
  for name in $SHEPHERD_CLIENT_HOOKS; do
    printf '#!/bin/sh\nexec "$(dirname "$0")/chain" %s "$@"\n' "$name" >"$dir/$name"
  done
  printf '%s\n' '#!/bin/sh' "gate='$root/hooks/git-pre-push.sh'" \
    'if [ ! -f "$gate" ]; then' \
    '  echo "shepherd: push gate $gate is missing. Run \`shepherd init\` on this branch to reinstall it, or \`git config --worktree --unset core.hooksPath\` to remove it." >&2' \
    '  exit 1' \
    'fi' \
    'refs=$(cat)' \
    'printf "%s\n" "$refs" | bash "$gate" "$@" || exit 1' \
    'printf "%s\n" "$refs" | exec "$(dirname "$0")/chain" pre-push "$@"' >"$dir/pre-push"
  chmod +x "$dir"/*
  git config --worktree core.hooksPath "$dir"
}
