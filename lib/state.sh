#!/usr/bin/env bash
# Shared state helpers for the shepherd hooks and the shepherd CLI.
# Sourced, never executed.
#
# State is per branch, under <repo>/.claude/shepherd/<branch>/, kept out of git
# through .git/info/exclude so the team's .gitignore is never touched:
#   brief.md      task contract: scope, success criteria, constraints
#   decisions.md  append-only log of non-obvious decisions and review records
#   state.json    machine state the hooks read: phase, PR, review budget, cleared tree

SHEPHERD_ACTIVE_PHASES="study implement review push triage"
SHEPHERD_WAIT_PHASES="waiting_ci waiting_review waiting_user done"
SHEPHERD_MAX_STOP_BLOCKS=3

shepherd_root() { git rev-parse --show-toplevel 2>/dev/null; }

shepherd_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

shepherd_dir() {
  local root branch
  root=$(shepherd_root) || return 1
  branch=$(shepherd_branch) || return 1
  [[ -n "$root" && -n "$branch" ]] || return 1
  printf '%s/.claude/shepherd/%s' "$root" "${branch//\//__}"
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
