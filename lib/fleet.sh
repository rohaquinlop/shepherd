#!/usr/bin/env bash
# Fleet: run a proposal's slices as parallel shepherd:run sessions, one per
# git worktree. Sourced by scripts/shepherd.sh after lib/state.sh.
#
# The record lives in the common git dir, so every worktree sees the same one:
#   shepherd/_fleet/<slug>.json        slices: title, depends, files, base, branch, worktree, session
#   shepherd/_fleet/worktrees/<slug>-slice-N/   the slice's worktree
#
# A dependent slice is stacked: it starts once each dependency is merged or
# ready (phase done with a PR), with at most one unmerged dependency, whose
# branch becomes its base. Status is read live from `claude agents --json`, each
# worktree's shepherd state, and `gh`; nothing here calls a model.

FLEET_RANK='{"ready":0,"input":1,"stalled":2,"running":3,"pending":4,"merged":5}'

fleet_dir() { printf '%s/_fleet' "$(shepherd_common_base)"; }

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

fleet_agents() { claude agents --json --all 2>/dev/null || die "\`claude agents --json\` failed"; }

fleet_live() {
  local agents
  agents=$(claude agents --json 2>/dev/null) || die "\`claude agents --json\` failed"
  jq -e --arg s "$1" 'any(.[]; .sessionId == $s)' >/dev/null <<<"$agents"
}

fleet_halt() {
  fleet_live "$1" || return 0
  claude stop "${1:0:8}" >/dev/null 2>&1 || die "cannot stop session ${1:0:8}"
}

# Live view of every slice as a JSON array, ranked.
fleet_rows() {
  local record="$1" agents n wt state branch pr pr_state rows="[]"
  agents=$(fleet_agents) || exit 1
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
         elif $a == null or $a.state == "blocked" then "stalled"
         else "running" end) as $cat
      | . + [{slice: ($n | tonumber), title: $s.title, category: $cat, rank: $rank[$cat],
              phase: $phase, pr: ($state.pr // null), question: ($state.question // null),
              branch: (if $branch == "" then $s.branch else $branch end), base: $s.base, target: $rec[0].target,
              session: $s.session, agent: ($a.state // null), depends: $s.depends, files: $s.files}]
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

fleet_dispatch() {
  local record="$1" n="$2" base="$3" slug proposal branch wt session ref
  slug=$(jq -r .slug "$record")
  proposal=$(jq -r .proposal "$record")
  branch="fleet/$slug/slice-$n"
  wt="$(fleet_dir)/worktrees/$slug-slice-$n"
  ref="$base"
  git rev-parse --verify -q "origin/$base" >/dev/null && ref="origin/$base"
  git worktree add -q -b "$branch" "$wt" "$ref" || die "cannot create worktree for slice-$n"
  session=$(uuidgen | tr '[:upper:]' '[:lower:]')
  if ! (cd "$wt" && claude --bg -n "shepherd-$slug-slice-$n" --session-id "$session" "/shepherd:run $proposal#slice-$n" >/dev/null); then
    git worktree remove --force "$wt"
    git branch -D -q "$branch"
    die "cannot start the session for slice-$n"
  fi
  jq --arg n "$n" --arg base "$base" --arg branch "$branch" --arg wt "$wt" --arg session "$session" \
    '.slices[$n] += {base: $base, branch: $branch, worktree: $wt, session: $session}' "$record" >"$record.tmp" \
    && mv "$record.tmp" "$record" \
    || die "slice-$n started as session ${session:0:8}, but the record was not updated; stop it with \`claude stop ${session:0:8}\`"
  echo "dispatched slice-$n on $base ($wt)"
}

fleet_next() {
  local record="$1" max target rows n base active dispatched=0
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
    fleet_dispatch "$record" "$n" "$base"
    dispatched=$((dispatched + 1))
  done
  (( dispatched > 0 )) || echo "nothing to dispatch"
}

fleet_start() {
  local proposal="$1" max=3 slug record dir parsed missing
  shift
  [[ "$1" == "--max" && -n "$2" ]] && max="$2"
  [[ -f "$proposal" ]] || die "fleet start <proposal> [--max N]"
  proposal=$(cd "$(dirname "$proposal")" && pwd -P)/$(basename "$proposal")
  slug=$(basename "$proposal" .md)
  dir=$(fleet_dir)
  record="$dir/$slug.json"
  [[ -f "$record" ]] && die "fleet '$slug' already started; use \`shepherd fleet next\`"
  parsed=$(fleet_parse "$proposal")
  [[ -n "$parsed" ]] || die "no \`### slice-N:\` sections in $proposal"
  mkdir -p "$dir/worktrees"
  jq -Rn --arg slug "$slug" --arg proposal "$proposal" --arg target "$(shepherd_target_branch)" \
    --argjson max "$max" --arg now "$(shepherd_now)" '
    {slug: $slug, proposal: $proposal, target: $target, max: $max, created: $now,
     slices: ([inputs | split("\t") | {key: .[0], value: {
       title: .[1],
       depends: (if .[2] == "" then [] else (.[2] | split(",") | map(tonumber)) end),
       files: (if .[3] == "" then [] else (.[3] | split(",")) end),
       base: null, branch: null, worktree: null, session: null}}] | from_entries)}
  ' <<<"$parsed" >"$record.tmp" || die "cannot write the fleet record"
  missing=$(jq -r '(.slices | keys) as $k | [.slices[].depends[] | tostring | select(. as $d | $k | index($d) | not)] | unique | map("slice-" + .) | join(", ")' "$record.tmp")
  [[ -z "$missing" ]] || { rm -f "$record.tmp"; die "unknown dependency: $missing"; }
  mv "$record.tmp" "$record"
  fleet_next "$record"
}

fleet_status() {
  local record="$1" json="$2" rows
  rows=$(fleet_rows "$record") || exit 1
  if [[ "$json" == "--json" ]]; then
    jq 'map(del(.rank))' <<<"$rows"
    return
  fi
  jq -r '.[] | [("slice-" + (.slice | tostring)), .category, (.phase // "-"),
    (if .pr then "#" + (.pr | tostring) else "-" end), (.branch // "-"), (.question // "")] | @tsv' <<<"$rows"
}

# Compares against the snapshot the last wait saw (`.seen` in the record), so a
# change made while the lead was busy between two waits is still reported.
fleet_wait() {
  local record="$1" timeout="${2:-1800}" interval="${SHEPHERD_FLEET_INTERVAL:-30}" seen now now_rows changed
  snapshot() { local rows; rows=$(fleet_rows "$record") || exit 1; jq -c 'map({slice, category, phase, pr}) | sort_by(.slice)' <<<"$rows"; }
  seen=$(jq -c '.seen // empty' "$record")
  if [[ -z "$seen" ]]; then
    seen=$(snapshot) || exit 1
    fleet_save_seen "$record" "$seen"
  fi
  now=$SECONDS
  while :; do
    now_rows=$(snapshot) || exit 1
    changed=$(jq -rn --argjson a "$seen" --argjson b "$now_rows" '
      [$b[] as $r | (first($a[] | select(.slice == $r.slice)) // {category: "new"}) as $o | select($o != $r)
       | "slice-\($r.slice): \($o.category)/\($o.phase // "-") -> \($r.category)/\($r.phase // "-")"] | .[]')
    if [[ -n "$changed" ]]; then
      fleet_save_seen "$record" "$now_rows"
      echo "$changed"
      return 0
    fi
    (( SECONDS - now < timeout )) || break
    sleep "$interval"
  done
  echo "no fleet change after ${timeout}s"
  exit 3
}

fleet_save_seen() {
  jq --argjson seen "$2" '.seen = $seen' "$1" >"$1.tmp" && mv "$1.tmp" "$1" || die "cannot write the fleet record"
}

fleet_set_base() {
  local record="$1" n="$2" base="$3"
  [[ -n "$n" && -n "$base" ]] || die "fleet base <slice> <branch>"
  jq -e --arg n "$n" '.slices[$n].session != null' "$record" >/dev/null || die "slice-$n has not started"
  jq --arg n "$n" --arg base "$base" '.slices[$n].base = $base' "$record" >"$record.tmp" \
    && mv "$record.tmp" "$record" || die "cannot write the fleet record"
}

fleet_answer() {
  local record="$1" n="$2" file="$3" session wt
  [[ -n "$n" && -f "$file" ]] || die "fleet answer <slice> <file>"
  session=$(jq -r --arg n "$n" '.slices[$n].session // empty' "$record")
  wt=$(jq -r --arg n "$n" '.slices[$n].worktree // empty' "$record")
  [[ -n "$session" && -d "$wt" ]] || die "slice-$n has no session"
  # Resuming a live session copies it into the caller's cwd, so stop it first
  # and resume from its own worktree.
  fleet_halt "$session"
  (cd "$wt" && claude --bg --resume "$session" "$(cat "$file")" >/dev/null) || die "cannot resume slice-$n"
  echo "answered slice-$n"
}

fleet_stop() {
  local record="$1" session
  for session in $(jq -r '.slices[].session // empty' "$record"); do
    fleet_live "$session" || continue
    claude stop "${session:0:8}" >/dev/null 2>&1 || die "cannot stop session ${session:0:8}"
    echo "stopped ${session:0:8}"
  done
}

# First fleet record for which the jq filter holds; $r is this checkout's root.
fleet_find() {
  local root file
  root=$(shepherd_root) || return 1
  for file in "$(fleet_dir)"/*.json; do
    [[ -f "$file" ]] || continue
    jq -e --arg r "$root" "$1" "$file" >/dev/null && { printf '%s' "$file"; return 0; }
  done
  return 1
}

# The fleet record whose lead runs in this checkout and is not done, if any.
fleet_lead_record() { fleet_find '.lead.root == $r and .lead.phase != "done"'; }

fleet_lead() {
  local record="$1" phase="$2"
  shepherd_in_list "$phase" "$SHEPHERD_LEAD_ACTIVE_PHASES $SHEPHERD_LEAD_WAIT_PHASES" \
    || die "fleet lead <$SHEPHERD_LEAD_ACTIVE_PHASES $SHEPHERD_LEAD_WAIT_PHASES>"
  jq --arg phase "$phase" --arg root "$(shepherd_root)" --arg now "$(shepherd_now)" \
    '.lead = {phase: $phase, root: $root, stop_blocks: 0, updated_at: $now}' "$record" >"$record.tmp" \
    && mv "$record.tmp" "$record" || die "cannot write the fleet record"
}

fleet_self() {
  local file
  file=$(fleet_find 'any(.slices[]; .worktree == $r)') || die "this worktree is not a fleet slice"
  jq --arg r "$(shepherd_root)" '
    . as $f | .slices | to_entries[] | select(.value.worktree == $r)
    | {slug: $f.slug, proposal: $f.proposal, slice: (.key | tonumber), base: .value.base, target: $f.target}
  ' "$file"
}

cmd_fleet() {
  local sub="$1" slug="" record
  shift
  [[ "$sub" == start ]] && { fleet_start "$@"; return; }
  [[ "$sub" == self ]] && { fleet_self; return; }
  if [[ "$1" == "--fleet" ]]; then slug="$2"; shift 2; fi
  case "$sub" in
    status|wait|next|answer|stop|lead|base) record=$(fleet_record "$slug") || exit 1 ;;
  esac
  case "$sub" in
    status) fleet_status "$record" "$1" ;;
    wait) [[ "$1" == "--timeout" ]] && shift; fleet_wait "$record" "$1" ;;
    next) fleet_next "$record" ;;
    answer) fleet_answer "$record" "$@" ;;
    stop) fleet_stop "$record" ;;
    lead) fleet_lead "$record" "$1" ;;
    base) fleet_set_base "$record" "$@" ;;
    *) die "fleet start <proposal> [--max N] | [--fleet SLUG] status [--json] | wait [--timeout S] | next | answer N FILE | base N BRANCH | stop | lead PHASE | self" ;;
  esac
}
