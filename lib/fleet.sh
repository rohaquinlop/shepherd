#!/usr/bin/env bash
# Fleet: run a proposal's slices as parallel shepherd:run sessions, one per
# git worktree. Sourced after lib/state.sh by scripts/shepherd.sh and the hooks.
#
# The record lives in the common git dir, so every worktree sees the same one:
#   shepherd/_fleet/<slug>.json        config_dir; slices: title, depends, files, base, branch, worktree, session, dispatch
#   shepherd/_fleet/worktrees/<slug>-slice-N/   the slice's worktree
#
# A dependent slice is stacked: it starts once each dependency is merged or
# ready (phase done with a PR), with at most one unmerged dependency, whose
# branch becomes its base. Status is read live from `claude agents --json`, each
# worktree's shepherd state, and `gh`; nothing here calls a model.

FLEET_RANK='{"ready":0,"input":1,"stalled":2,"running":3,"pending":4,"merged":5}'

fleet_dir() { printf '%s/_fleet' "$(shepherd_common_base)"; }

# Applies a jq filter to a record under a lock: the background `fleet wait`
# writes `.seen` while the lead writes `.lead`, so an unlocked write can drop
# the other one.
fleet_write() {
  local record="$1" tmp rc=1
  shift
  shepherd_lock "$record.lock" 2>/dev/null || { echo "shepherd: fleet record $record is locked by another write" >&2; return 1; }
  tmp=$(mktemp "$record.XXXXXX") && jq "$@" "$record" >"$tmp" && mv "$tmp" "$record" && rc=0
  (( rc == 0 )) || rm -f "$tmp"
  rm -rf "$record.lock"
  return "$rc"
}

fleet_record() {
  local slug="$1" dir files
  dir=$(fleet_dir)
  if [[ -n "$slug" ]]; then
    [[ -f "$dir/$slug.json" ]] || die "no fleet '$slug'"
    printf '%s/%s.json' "$dir" "$slug"
    return
  fi
  files=$(find "$dir" -maxdepth 1 -name '*.json' 2>/dev/null)
  [[ -n "$files" ]] || die "no fleet started; run \`shepherd fleet start <proposal>\`"
  (( $(wc -l <<<"$files") == 1 )) || die "several fleets; pass --fleet <slug>: $(xargs -n1 basename <<<"$files" | sed 's/\.json$//' | xargs)"
  printf '%s' "$files"
}

# One TSV row per slice: number, title, dependency numbers, files (comma-joined).
fleet_parse() {
  awk '
    function flush() { if (n != "") printf "%s\t%s\t%s\t%s\n", n, title, deps, files }
    /^### slice-[0-9]+:/ {
      flush()
      n = $2; sub(/^slice-/, "", n); sub(/:$/, "", n)
      title = $0; sub(/^### slice-[0-9]+:[ \t]*/, "", title)
      deps = ""; files = ""; next
    }
    n != "" && /^- \*\*Depends on:\*\*/ {
      line = $0
      while (match(line, /slice-[0-9]+/)) {
        d = substr(line, RSTART + 6, RLENGTH - 6)
        deps = deps (deps == "" ? "" : ",") d
        line = substr(line, RSTART + RLENGTH)
      }
    }
    n != "" && /^- \*\*Files:\*\*/ {
      line = $0
      while (match(line, /`[^`]+`/)) {
        f = substr(line, RSTART + 1, RLENGTH - 2)
        files = files (files == "" ? "" : ",") f
        line = substr(line, RSTART + RLENGTH)
      }
    }
    /^###? / && n != "" { flush(); n = "" }
    END { flush() }
  ' "$1"
}

# The lead's shell may wrap `claude` in an alias or function that sets
# CLAUDE_CONFIG_DIR; this script sees neither, so it passes the config dir
# recorded at `fleet start`, and `claude agents|logs|stop` see the same sessions.
fleet_config_dir() { jq -r --arg env "${CLAUDE_CONFIG_DIR:-}" '.config_dir // $env' "$1"; }

fleet_claude() {
  local dir
  dir=$(fleet_config_dir "$1")
  shift
  if [[ -n "$dir" ]]; then CLAUDE_CONFIG_DIR="$dir" command claude "$@"; else command claude "$@"; fi
}

fleet_agents() { fleet_claude "$1" agents --json --all 2>/dev/null || die "\`claude agents --json\` failed"; }

fleet_live() {
  local agents
  agents=$(fleet_claude "$1" agents --json 2>/dev/null) || die "\`claude agents --json\` failed"
  jq -e --arg s "$2" 'any(.[]; .sessionId == $s)' >/dev/null <<<"$agents"
}

fleet_halt() {
  fleet_live "$1" "$2" || return 0
  fleet_claude "$1" stop "${2:0:8}" >/dev/null 2>&1 || die "cannot stop session ${2:0:8}"
}

# Live view of every slice as a JSON array, ranked.
fleet_rows() {
  local record="$1" agents='[]' n wt state branch pr pr_state rows="[]"
  if jq -e 'any(.slices[]; .session != null and .dispatch != "external")' "$record" >/dev/null; then
    agents=$(fleet_agents "$record") || exit 1
  fi
  for n in $(jq -r '.slices | keys[]' "$record" | sort -n); do
    wt=$(jq -r --arg n "$n" '.slices[$n].worktree // empty' "$record")
    state='{}'; branch=""; pr_state=""
    if [[ -n "$wt" && -d "$wt" ]]; then
      state=$(cd "$wt" && f=$(shepherd_state_file) && [[ -f "$f" ]] && cat "$f" || echo '{}')
      branch=$(git -C "$wt" branch --show-current 2>/dev/null)
      pr=$(jq -r '.pr // empty' <<<"$state")
      [[ -n "$pr" ]] && pr_state=$(cd "$wt" && gh pr view "$pr" --json state -q .state 2>/dev/null)
    fi
    rows=$(jq --arg n "$n" --argjson state "$state" --argjson agents "$agents" \
      --arg branch "$branch" --arg pr_state "$pr_state" --slurpfile rec "$record" --argjson rank "$FLEET_RANK" '
      ($rec[0].slices[$n]) as $s
      | ([$agents[] | select(.sessionId == $s.session)][0] // null) as $a
      | ($state.phase // null) as $phase
      | (if $pr_state == "MERGED" then "merged"
         elif $s.session == null then "pending"
         elif $phase == "done" and ($state.pr != null) then "ready"
         elif $phase == "waiting_user" then "input"
         elif $s.dispatch != "external" and ($a == null or $a.state == "blocked") then "stalled"
         else "running" end) as $cat
      | . + [{slice: ($n | tonumber), title: $s.title, category: $cat, rank: $rank[$cat],
              phase: $phase, pr: ($state.pr // null), question: ($state.question // null),
              branch: (if $branch == "" then $s.branch else $branch end), base: $s.base, target: $rec[0].target,
              session: $s.session, dispatch: ($s.dispatch // null), agent: ($a.state // null),
              depends: $s.depends, files: $s.files}]
      ' <<<"$rows")
  done
  jq 'sort_by(.rank, .slice)' <<<"$rows"
}

# Base for a pending slice, or empty when it cannot start yet.
fleet_base() {
  local rows="$1" n="$2" target="$3"
  jq -r --argjson n "$n" --arg target "$target" '
    (map({key: (.slice | tostring), value: .}) | from_entries) as $by
    | $by[$n | tostring] as $s
    | [$s.depends[] | $by[tostring]] as $deps
    | if any($deps[]; .category != "merged" and .category != "ready") then empty
      elif ([$deps[] | select(.category == "ready")] | length) > 1 then empty
      elif any(.[]; .session != null and .category != "merged" and .slice != $n
               and (.slice as $x | $s.depends | index($x) | not)
               and ((.files - (.files - $s.files)) | length) > 0) then empty
      else ([$deps[] | select(.category == "ready") | .branch][0] // $target) end
  ' <<<"$rows"
}

# Session id of the background job named $1 that started at or after epoch
# second $2. `claude --bg` picks the id itself and can exit 0 without starting a
# job, so the job is looked up by its name until it shows up or time runs out.
fleet_await_session() {
  local record="$1" name="$2" since="$3" timeout="${SHEPHERD_FLEET_START_TIMEOUT:-30}" start=$SECONDS session
  while :; do
    session=$(fleet_claude "$record" agents --json --all 2>/dev/null | jq -r --arg name "$name" --argjson since "$since" '
      [.[] | select(.name == $name and (.startedAt // 0) >= $since * 1000)] | sort_by(.startedAt) | last | .sessionId // empty' 2>/dev/null)
    [[ -n "$session" ]] && { printf '%s' "$session"; return 0; }
    (( SECONDS - start < timeout )) || return 1
    sleep 1
  done
}

fleet_bg() {
  local record="$1" wt="$2" name="$3" prompt="$4" since
  since=$(date +%s)
  (cd "$wt" && fleet_claude "$record" --bg -n "$name" "$prompt" >/dev/null) && fleet_await_session "$record" "$name" "$since"
}

fleet_dispatch() {
  local record="$1" n="$2" base="$3" mode="$4" slug proposal branch wt name session ref
  slug=$(jq -r .slug "$record")
  proposal=$(jq -r .proposal "$record")
  branch="fleet/$slug/slice-$n"
  wt="$(fleet_dir)/worktrees/$slug-slice-$n"
  name="shepherd-$slug-slice-$n"
  ref="$base"
  git rev-parse --verify -q "origin/$base" >/dev/null && ref="origin/$base"
  git worktree add -q -b "$branch" "$wt" "$ref" || die "cannot create worktree for slice-$n"
  # Recorded before the start, so the session's own `fleet self` finds it. The
  # job name holds the session's place until its real id is known (or, for an
  # external slice, until `fleet bind`).
  if ! fleet_write "$record" --arg n "$n" --arg base "$base" --arg branch "$branch" --arg wt "$wt" --arg session "$name" \
    --arg mode "$mode" '.slices[$n] += {base: $base, branch: $branch, worktree: $wt, session: $session}
      + (if $mode == "external" then {dispatch: "external"} else {} end)'; then
    git worktree remove --force "$wt"
    git branch -D -q "$branch"
    die "cannot write the fleet record"
  fi
  if [[ "$mode" == external ]]; then
    printf 'slice-%s\t%s\t%s\n' "$n" "$wt" "/shepherd:run $proposal#slice-$n"
    return
  fi
  if ! session=$(fleet_bg "$record" "$wt" "$name" "/shepherd:run $proposal#slice-$n"); then
    fleet_write "$record" --arg n "$n" '.slices[$n] += {base: null, branch: null, worktree: null, session: null}' \
      || echo "shepherd: set .slices[\"$n\"].base, .branch, .worktree, and .session to null in $record, or slice-$n never starts" >&2
    git worktree remove --force "$wt"
    git branch -D -q "$branch"
    die "cannot start the session for slice-$n; if a job named $name shows up later, stop it"
  fi
  fleet_write "$record" --arg n "$n" --arg session "$session" '.slices[$n].session = $session' \
    || die "slice-$n runs as session $session; set .slices[\"$n\"].session to it in $record"
  echo "dispatched slice-$n on $base ($wt)"
}

# For an external slice the app could not open: runs it as a CLI background
# session in its worktree instead.
fleet_launch() {
  local record="$1" n="$2" slug proposal wt name session
  slug=$(jq -r .slug "$record")
  proposal=$(jq -r .proposal "$record")
  name="shepherd-$slug-slice-$n"
  [[ -n "$n" ]] || die "fleet launch <slice>"
  jq -e --arg n "$n" --arg name "$name" '.slices[$n] | .dispatch == "external" and .session == $name' "$record" >/dev/null \
    || die "slice-$n is not an unbound external slice"
  wt=$(jq -r --arg n "$n" '.slices[$n].worktree' "$record")
  session=$(fleet_bg "$record" "$wt" "$name" "/shepherd:run $proposal#slice-$n") \
    || die "cannot start the session for slice-$n; if a job named $name shows up later, stop it"
  fleet_write "$record" --arg n "$n" --arg session "$session" '.slices[$n].session = $session | del(.slices[$n].dispatch)' \
    || die "slice-$n runs as session $session; set .slices[\"$n\"].session to it and delete .dispatch in $record"
  echo "dispatched slice-$n ($wt)"
}

fleet_bind() {
  local record="$1" n="$2" ref="$3"
  [[ -n "$n" && -n "$ref" ]] || die "fleet bind <slice> <session-ref>"
  jq -e --arg n "$n" '.slices[$n].dispatch == "external"' "$record" >/dev/null || die "slice-$n is not an external slice"
  fleet_write "$record" --arg n "$n" --arg ref "$ref" '.slices[$n].session = $ref' || die "cannot write the fleet record"
}

fleet_cli_session() {
  local record="$1" n="$2" session
  jq -e --arg n "$n" '.slices[$n].dispatch == "external"' "$record" >/dev/null \
    && die "slice-$n is an external session; open it where it runs"
  session=$(jq -r --arg n "$n" '.slices[$n].session // empty' "$record")
  [[ -n "$session" ]] || die "slice-$n has not started"
  [[ "$session" == "shepherd-$(jq -r .slug "$record")-slice-$n" ]] && die "slice-$n is still starting"
  printf '%s' "${session:0:8}"
}

fleet_logs() {
  local record="$1" n="$2" lines=200 session
  if [[ "$3" == "--tail" ]]; then
    [[ "$4" =~ ^[0-9]+$ ]] || die "fleet logs <slice> [--tail N]"
    lines="$4"
  fi
  session=$(fleet_cli_session "$record" "$n") || exit 1
  fleet_claude "$record" logs "$session" | tail -n "$lines"
}

fleet_attach() {
  local record="$1" n="$2" session dir
  session=$(fleet_cli_session "$record" "$n") || exit 1
  dir=$(fleet_config_dir "$record")
  if [[ -n "$dir" ]]; then printf 'CLAUDE_CONFIG_DIR=%q claude attach %s\n' "$dir" "$session"; else echo "claude attach $session"; fi
}

fleet_slices() {
  fleet_parse "$1" | jq -Rn '
    [inputs | split("\t") | {key: .[0], value: {
      title: .[1],
      depends: (if .[2] == "" then [] else (.[2] | split(",") | map(tonumber)) end),
      files: (if .[3] == "" then [] else (.[3] | split(",")) end),
      base: null, branch: null, worktree: null, session: null}}] | from_entries'
}

fleet_missing() {
  jq -r '(keys) as $k | [.[].depends[] | tostring | select(. as $d | $k | index($d) | not)] | unique | map("slice-" + .) | join(", ")' <<<"$1"
}

# A started slice stays as recorded: its session has already read the proposal.
fleet_sync() {
  local record="$1" proposal slices missing merge
  proposal=$(jq -r .proposal "$record")
  [[ -f "$proposal" ]] || die "proposal $proposal is gone"
  slices=$(fleet_slices "$proposal")
  merge='$s + .slices | with_entries(if .value.session == null and $s[.key] != null then .value = $s[.key] else . end)'
  missing=$(fleet_missing "$(jq --argjson s "$slices" "$merge" "$record")")
  [[ -z "$missing" ]] || die "unknown dependency: $missing"
  fleet_write "$record" --argjson s "$slices" ".slices = ($merge)" || die "cannot write the fleet record"
}

fleet_mode() {
  case "$1" in
    "") echo bg ;;
    --dispatch) [[ "$2" == external ]] || die "--dispatch takes \`external\`"; echo external ;;
    *) die "unknown option $1" ;;
  esac
}

fleet_next() {
  local record="$1" mode="$2" max target rows n base active dispatched=0
  fleet_sync "$record"
  max=$(jq -r '.max // 3' "$record")
  target=$(jq -r .target "$record")
  git fetch -q origin 2>/dev/null
  while :; do
    rows=$(fleet_rows "$record") || exit 1
    active=$(jq '[.[] | select(.category == "running" or .category == "input" or .category == "stalled")] | length' <<<"$rows")
    (( active < max )) || break
    base=""
    for n in $(jq -r '.[] | select(.category == "pending") | .slice' <<<"$rows" | sort -n); do
      base=$(fleet_base "$rows" "$n" "$target")
      [[ -n "$base" ]] && break
    done
    [[ -n "$base" ]] || break
    fleet_dispatch "$record" "$n" "$base" "$mode"
    dispatched=$((dispatched + 1))
  done
  (( dispatched > 0 )) || echo "nothing to dispatch"
}

fleet_start() {
  local proposal="$1" max=3 mode=bg slug record dir slices missing
  shift
  while (( $# )); do
    case "$1" in
      --max) [[ -n "$2" ]] || die "--max takes a number"; max="$2"; shift 2 ;;
      *) mode=$(fleet_mode "$1" "$2") || exit 1; shift 2 ;;
    esac
  done
  [[ -f "$proposal" ]] || die "fleet start <proposal> [--max N] [--dispatch external]"
  proposal=$(cd "$(dirname "$proposal")" && pwd -P)/$(basename "$proposal")
  slug=$(basename "$proposal" .md)
  dir=$(fleet_dir)
  record="$dir/$slug.json"
  [[ -f "$record" ]] && die "fleet '$slug' already started; use \`shepherd fleet next\`"
  slices=$(fleet_slices "$proposal")
  [[ "$slices" != "{}" ]] || die "no \`### slice-N:\` sections in $proposal"
  missing=$(fleet_missing "$slices")
  [[ -z "$missing" ]] || die "unknown dependency: $missing"
  mkdir -p "$dir/worktrees"
  jq -n --arg slug "$slug" --arg proposal "$proposal" --arg target "$(shepherd_target_branch)" \
    --argjson max "$max" --arg now "$(shepherd_now)" --argjson slices "$slices" \
    --arg config_dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
    '{slug: $slug, proposal: $proposal, target: $target, max: $max, created: $now, config_dir: $config_dir, slices: $slices}' \
    >"$record.tmp" && mv "$record.tmp" "$record" || die "cannot write the fleet record"
  fleet_next "$record" "$mode"
}

fleet_status() {
  local record="$1" json="$2" rows dir
  rows=$(fleet_rows "$record") || exit 1
  if [[ "$json" == "--json" ]]; then
    jq 'map(del(.rank))' <<<"$rows"
    return
  fi
  dir=$(fleet_config_dir "$record"); echo "config_dir ${dir:-$HOME/.claude}"
  jq -r '.[] | [("slice-" + (.slice | tostring)), .category, (.phase // "-"),
    (if .pr then "#" + (.pr | tostring) else "-" end), (.branch // "-"), (.question // "")] | @tsv' <<<"$rows"
}

# Compares against the snapshot the last wait saw (`.seen` in the record), so a
# change made while the lead was busy between two waits is still reported. The
# first wait compares against nothing, so it reports a slice already waiting.
fleet_wait() {
  local record="$1" timeout="${2:-1800}" interval="${SHEPHERD_FLEET_INTERVAL:-30}" seen now now_rows changed
  snapshot() { local rows; rows=$(fleet_rows "$record") || exit 1; jq -c 'map({slice, category, phase, pr, question}) | sort_by(.slice)' <<<"$rows"; }
  seen=$(jq -c '.seen // []' "$record")
  now=$SECONDS
  while :; do
    now_rows=$(snapshot) || exit 1
    changed=$(jq -rn --argjson a "$seen" --argjson b "$now_rows" '
      [$b[] as $r | (first($a[] | select(.slice == $r.slice)) // {category: "new"}) as $o | select($o != $r)
       | "slice-\($r.slice): \($o.category)/\($o.phase // "-") -> \($r.category)/\($r.phase // "-")"] | .[]')
    if [[ -n "$changed" ]]; then
      seen=$now_rows
      fleet_save_seen "$record" "$seen"
      # The lead's own dispatches, answers, and re-plans move a slice from
      # new, pending, input, or ready to running or pending; those do not wake it.
      changed=$(grep -Ev '^slice-[0-9]+: (new|pending|input|ready)/[^ ]* -> (running|pending)/' <<<"$changed")
      [[ -n "$changed" ]] && { echo "$changed"; return 0; }
    fi
    (( SECONDS - now < timeout )) || break
    sleep "$interval"
  done
  echo "no fleet change after ${timeout}s"
  exit 3
}

fleet_save_seen() {
  fleet_write "$1" --argjson seen "$2" '.seen = $seen' || die "cannot write the fleet record"
}

fleet_set_base() {
  local record="$1" n="$2" base="$3"
  [[ -n "$n" && -n "$base" ]] || die "fleet base <slice> <branch>"
  jq -e --arg n "$n" '.slices[$n].session != null' "$record" >/dev/null || die "slice-$n has not started"
  fleet_write "$record" --arg n "$n" --arg base "$base" '.slices[$n].base = $base' || die "cannot write the fleet record"
}

fleet_answer() {
  local record="$1" n="$2" file="$3" session wt
  [[ -n "$n" && -f "$file" ]] || die "fleet answer <slice> <file>"
  session=$(jq -r --arg n "$n" '.slices[$n].session // empty' "$record")
  wt=$(jq -r --arg n "$n" '.slices[$n].worktree // empty' "$record")
  [[ -n "$session" && -d "$wt" ]] || die "slice-$n has no session"
  if jq -e --arg n "$n" '.slices[$n].dispatch == "external"' "$record" >/dev/null; then
    [[ "$session" == "shepherd-$(jq -r .slug "$record")-slice-$n" ]] && die "slice-$n is not bound yet; run \`fleet bind $n <session-ref>\` first"
    echo "slice-$n runs as external session $session in $wt; send it this answer:"
    cat "$file"
    return
  fi
  # Resuming a live session copies it into the caller's cwd, so stop it first
  # and resume from its own worktree.
  fleet_halt "$record" "$session"
  (cd "$wt" && fleet_claude "$record" --bg --resume "$session" "$(cat "$file")" >/dev/null) || die "cannot resume slice-$n"
  echo "answered slice-$n"
}

fleet_stop() {
  local record="$1" session
  jq -r '.slices | to_entries[] | select(.value.dispatch == "external" and .value.session != null)
    | "not stopped: slice-\(.key) runs as external session \(.value.session); stop it where it runs"' "$record"
  for session in $(jq -r '.slices[] | select(.dispatch != "external") | .session // empty' "$record"); do
    fleet_live "$record" "$session" || continue
    fleet_claude "$record" stop "${session:0:8}" >/dev/null 2>&1 || die "cannot stop session ${session:0:8}"
    echo "stopped ${session:0:8}"
  done
}

fleet_find() {
  local filter="$1" root file
  shift
  root=$(shepherd_root) || return 1
  for file in "$(fleet_dir)"/*.json; do
    [[ -f "$file" ]] || continue
    jq -e --arg r "$root" "$@" "$filter" "$file" >/dev/null && { printf '%s' "$file"; return 0; }
  done
  return 1
}

fleet_lead_record() { fleet_find '.lead.root == $r and .lead.phase != "done" and .lead.session == $s' --arg s "$1"; }

fleet_lead() {
  local record="$1" phase="$2"
  shepherd_in_list "$phase" "$SHEPHERD_LEAD_ACTIVE_PHASES $SHEPHERD_LEAD_WAIT_PHASES" \
    || die "fleet lead <$SHEPHERD_LEAD_ACTIVE_PHASES $SHEPHERD_LEAD_WAIT_PHASES>"
  [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]] || die "fleet lead runs only in a Claude Code session (CLAUDE_CODE_SESSION_ID is not set)"
  fleet_write "$record" --arg phase "$phase" --arg root "$(shepherd_root)" --arg now "$(shepherd_now)" \
    --arg session "$CLAUDE_CODE_SESSION_ID" \
    '.lead = {phase: $phase, root: $root, session: $session, stop_blocks: 0, updated_at: $now}' || die "cannot write the fleet record"
}

fleet_self() {
  local file
  file=$(fleet_find 'any(.slices[]; .worktree == $r)') || die "this worktree is not a fleet slice"
  jq --arg r "$(shepherd_root)" '
    . as $f | .slices | to_entries[] | select(.value.worktree == $r)
    | {slug: $f.slug, slice: (.key | tonumber), base: .value.base, target: $f.target}
  ' "$file"
}

cmd_fleet() {
  local sub="$1" slug="" record mode
  shift
  [[ "$sub" == start ]] && { fleet_start "$@"; return; }
  [[ "$sub" == self ]] && { fleet_self; return; }
  if [[ "$1" == "--fleet" ]]; then slug="$2"; shift 2; fi
  case "$sub" in
    status|wait|next|answer|stop|lead|base|logs|attach|bind|launch) record=$(fleet_record "$slug") || exit 1 ;;
  esac
  case "$sub" in
    status) fleet_status "$record" "$1" ;;
    wait) [[ "$1" == "--timeout" ]] && shift; fleet_wait "$record" "$1" ;;
    next) mode=$(fleet_mode "$@") || exit 1; fleet_next "$record" "$mode" ;;
    answer) fleet_answer "$record" "$@" ;;
    stop) fleet_stop "$record" ;;
    lead) fleet_lead "$record" "$1" ;;
    base) fleet_set_base "$record" "$@" ;;
    logs) fleet_logs "$record" "$@" ;;
    attach) fleet_attach "$record" "$1" ;;
    bind) fleet_bind "$record" "$@" ;;
    launch) fleet_launch "$record" "$1" ;;
    *) die "fleet start <proposal> [--max N] [--dispatch external] | status [--json] | wait [--timeout S] | next [--dispatch external] | answer N FILE | base N BRANCH | logs N [--tail N] | attach N | bind N REF | launch N | stop | lead PHASE (each takes --fleet SLUG after it) | self" ;;
  esac
}
