#!/usr/bin/env bash
# State location, legacy migration, and the diagnose guard, on throwaway repos.
# usage: bash tests/state_dir.sh [shepherd checkout]   (default: this checkout)
set -u
REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; CLI="$REPO/scripts/shepherd.sh"; HOOKS="$REPO/hooks"
T=$(cd "$(mktemp -d)" && pwd -P); pass=0; fail=0
ok() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
mkrepo() { git init -q -b main "$1" && git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }
sh() { (cd "$1" && shift && bash "$CLI" "$@"); }

# 1. init -> git dir
mkrepo "$T/a"; git -C "$T/a" switch -q -c feat/x
d=$(sh "$T/a" init 2>/dev/null)
ok "init dir under git dir" '[[ "$d" == "$T/a/.git/shepherd/feat__x" && -f "$d/state.json" ]]'
ok "no .claude dir created" '[[ ! -e "$T/a/.claude" ]]'
ok "no exclude entry" '! grep -qs shepherd "$T/a/.git/info/exclude"'

# 2. diagnose + guard (main worktree)
out=$(sh "$T/a" diagnose start --slug probe)
scr=$(sed -n 's/^scratch: //p' <<<"$out")
ok "diagnose under git dir" '[[ -f "$T/a/.git/shepherd/_diagnose/active.json" && "$scr" == "$T/a/.git/shepherd/_diagnose/scratch/probe" && -d "$scr" ]]'
guard() { jq -n --arg cwd "$1" --arg f "$2" '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$f}}' | bash "$HOOKS/diagnose-guard.sh"; }
ok "guard allows scratch" '[[ -z "$(guard "$T/a" "$scr/p.sh")" ]]'
ok "guard denies src" 'guard "$T/a" "$T/a/src.c" | grep -q deny'
ok "propose refused while diagnosis active" '! sh "$T/a" propose start --slug idea 2>/dev/null'
ok "propose status names active diagnosis" 'sh "$T/a" propose status | grep -q "diagnosis .probe. is active"'
ok "propose end refused for a diagnosis" '! sh "$T/a" propose end 2>/dev/null && [[ -f "$T/a/.git/shepherd/_diagnose/active.json" ]]'
sh "$T/a" diagnose end >/dev/null

# 2b. propose + guard
out=$(sh "$T/a" propose start --slug idea)
w=$(sed -n 's/^writeup: //p' <<<"$out"); scr=$(sed -n 's/^scratch: //p' <<<"$out")
ok "proposal write-up from template" '[[ "$w" == "$T/a/docs/proposals/"*-idea.md ]] && head -1 "$w" | grep -q "^# Proposal"'
ok "proposal kind recorded" '[[ "$(jq -r .kind "$T/a/.git/shepherd/_diagnose/active.json")" == proposal ]]'
ok "proposal guard allows write-up" '[[ -z "$(guard "$T/a" "$w")" ]]'
ok "proposal guard allows scratch" '[[ -z "$(guard "$T/a" "$scr/spike.sh")" ]]'
ok "proposal guard denies src" 'guard "$T/a" "$T/a/src.c" | grep -q "shepherd propose:.*proposal"'
ok "proposal guard denies docs/diagnoses" 'guard "$T/a" "$T/a/docs/diagnoses/x.md" | grep -q deny'
ok "diagnose end refused for a proposal" '! sh "$T/a" diagnose end 2>/dev/null'
ok "diagnose start refused while proposal active" '! sh "$T/a" diagnose start --slug other 2>/dev/null'
sh "$T/a" propose end >/dev/null
ok "proposal ended" '[[ ! -e "$T/a/.git/shepherd/_diagnose/active.json" && -f "$w" ]]'
jq -n --arg s "$scr" '{slug:"old", writeup:"w", scratch:$s}' > "$T/a/.git/shepherd/_diagnose/active.json"
ok "kindless active.json is a diagnosis" 'sh "$T/a" propose status | grep -q "diagnosis .old. is active"'
ok "kindless guard allows docs/diagnoses" '[[ -z "$(guard "$T/a" "$T/a/docs/diagnoses/x.md")" ]]'
ok "kindless guard denies docs/proposals" 'guard "$T/a" "$T/a/docs/proposals/x.md" | grep -q "Diagnosis .old. is active: diagnose only"'
rm "$T/a/.git/shepherd/_diagnose/active.json"

# 3. legacy migration
mkrepo "$T/b"; git -C "$T/b" switch -q -c fix/y
L="$T/b/.claude/shepherd"; mkdir -p "$L/fix__y" "$L/_diagnose/scratch/s" "$T/b/.claude"
echo '{"k":1}' > "$T/b/.claude/shepherd.json"
jq -n --arg b "$L/fix__y/last-bundle.md" '{phase:"implement", stop_blocks:2, updated_at:"OLD", bundle_path:$b}' > "$L/fix__y/state.json"
jq -n --arg s "$L/_diagnose/scratch/s" '{slug:"s", writeup:"w", scratch:$s}' > "$L/_diagnose/active.json"
st=$(sh "$T/b" status)
B="$T/b/.git/shepherd"
ok "status reads migrated state" '[[ "$(jq -r .phase <<<"$st")" == implement ]]'
ok "legacy dir removed" '[[ ! -e "$L" ]]'
ok "shepherd.json untouched" '[[ "$(cat "$T/b/.claude/shepherd.json")" == "{\"k\":1}" ]]'
ok "bundle_path repointed" '[[ "$(jq -r .bundle_path "$B/fix__y/state.json")" == "$B/fix__y/last-bundle.md" ]]'
ok "updated_at/stop_blocks kept" '[[ "$(jq -r "[.updated_at,.stop_blocks]|join(\",\")" "$B/fix__y/state.json")" == "OLD,2" ]]'
ok "scratch repointed" '[[ "$(jq -r .scratch "$B/_diagnose/active.json")" == "$B/_diagnose/scratch/s" ]]'
ok "second run no-op" '[[ -z "$(sh "$T/b" status 2>&1 >/dev/null)" ]]'
ok "no lock left" '[[ ! -e "$B.migrate.lock" ]]'

# collision
mkdir -p "$L/fix__y" "$L/other"; touch "$L/.DS_Store"; echo '{"phase":"study"}' > "$L/fix__y/state.json"; echo '{}' > "$L/other/state.json"
err=$(sh "$T/b" status 2>&1 >/dev/null)
ok "collision: new kept" '[[ "$(jq -r .phase "$B/fix__y/state.json")" == implement ]]'
ok "collision: old copy moved aside" '[[ "$(jq -r .phase "$B/fix__y.legacy/state.json")" == study ]]'
ok "collision: warning names both" 'grep -q "$B/fix__y.legacy" <<<"$err" && grep -q "kept $B/fix__y" <<<"$err"'
ok "collision: free entry moved" '[[ -f "$B/other/state.json" && ! -e "$L" ]]'
ok "collision: dotfile moved, legacy dir gone" '[[ -e "$B/.DS_Store" && ! -e "$L" ]]'
ok "collision: warns once" '[[ -z "$(sh "$T/b" status 2>&1 >/dev/null)" ]]'

# stale lock
mkrepo "$T/c"; git -C "$T/c" switch -q -c z
mkdir -p "$T/c/.claude/shepherd/z"; echo '{"phase":"implement"}' > "$T/c/.claude/shepherd/z/state.json"
mkdir -p "$T/c/.git/shepherd.migrate.lock"; echo 999999 > "$T/c/.git/shepherd.migrate.lock/pid"
err=$(sh "$T/c" status 2>&1 >/dev/null)
ok "stale lock taken over" '[[ -f "$T/c/.git/shepherd/z/state.json" && ! -e "$T/c/.git/shepherd.migrate.lock" ]]'
ok "stale lock warning names path" 'grep -q "$T/c/.git/shepherd.migrate.lock" <<<"$err"'

# lock with no pid (crash between mkdir and pid write)
mkrepo "$T/c2"; git -C "$T/c2" switch -q -c z
mkdir -p "$T/c2/.claude/shepherd/z"; echo '{"phase":"implement"}' > "$T/c2/.claude/shepherd/z/state.json"
mkdir -p "$T/c2/.git/shepherd.migrate.lock"
err=$(sh "$T/c2" status 2>&1 >/dev/null)
ok "empty-pid lock taken over" '[[ -f "$T/c2/.git/shepherd/z/state.json" && ! -e "$T/c2/.git/shepherd.migrate.lock" ]] && grep -q "no pid" <<<"$err"'

# stop hook with only legacy state still blocks
mkrepo "$T/d"; git -C "$T/d" switch -q -c z
mkdir -p "$T/d/.claude/shepherd/z"; echo '{"phase":"implement","stop_blocks":0}' > "$T/d/.claude/shepherd/z/state.json"
ok "stop hook blocks on legacy state" 'jq -n --arg cwd "$T/d" "{cwd:\$cwd}" | bash "$HOOKS/stop.sh" | grep -q block'

# concurrency
for n in 1 2 3; do
  mkrepo "$T/e$n"; git -C "$T/e$n" switch -q -c z
  mkdir -p "$T/e$n/.claude/shepherd/z" "$T/e$n/.claude/shepherd/_diagnose"
  echo '{"phase":"implement"}' > "$T/e$n/.claude/shepherd/z/state.json"
  for i in 1 2 3 4 5 6; do (sh "$T/e$n" status >"$T/e$n.out$i" 2>&1) & done; wait
  ok "concurrent $n: all readers see state" '[[ $(grep -l "\"implement\"" "$T/e$n".out* | wc -l) -eq 6 ]]'
  ok "concurrent $n: no nesting" '[[ ! -e "$T/e$n/.git/shepherd/shepherd" && ! -e "$T/e$n/.claude/shepherd" && -f "$T/e$n/.git/shepherd/z/state.json" ]]'
done

# linked + detached worktrees
git -C "$T/a" worktree add -q "$T/wt1" -b w1; git -C "$T/a" worktree add -q --detach "$T/wt2"; git -C "$T/a" worktree add -q --detach "$T/wt3"
d1=$(sh "$T/wt1" init); d2=$(sh "$T/wt2" init); d3=$(sh "$T/wt3" init)
ok "linked worktree dir" '[[ "$d1" == "$T/a/.git/worktrees/wt1/shepherd/w1" ]]'
ok "detached worktrees distinct" '[[ "$d2" != "$d3" && -f "$d2/state.json" && -f "$d3/state.json" ]]'
out=$(sh "$T/wt1" diagnose start --slug p); scr=$(sed -n 's/^scratch: //p' <<<"$out")
ok "linked guard allows scratch" '[[ -z "$(guard "$T/wt1" "$scr/p.sh")" ]]'
ok "linked guard denies src" 'guard "$T/wt1" "$T/wt1/src.c" | grep -q deny'
ok "linked guard denies state dir" 'guard "$T/wt1" "$d1/state.json" | grep -q deny'
ok "linked guard denies active.json" 'guard "$T/wt1" "$T/a/.git/worktrees/wt1/shepherd/_diagnose/active.json" | grep -q deny'
ok "main worktree not guarded by linked diagnosis" '[[ -z "$(guard "$T/a" "$T/a/src.c")" ]]'

echo "pass=$pass fail=$fail"; rm -rf "$T"
(( fail == 0 ))
