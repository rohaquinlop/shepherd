#!/usr/bin/env bash
# shepherd fleet on a throwaway repo, with fake `claude` and `gh` on PATH.
# usage: bash tests/fleet.sh [shepherd checkout]   (default: this checkout)
set -u
REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; CLI="$REPO/scripts/shepherd.sh"; HOOKS="$REPO/hooks"
T=$(cd "$(mktemp -d)" && pwd -P); pass=0; fail=0
ok() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
sh() { (cd "$1" && shift && bash "$CLI" "$@"); }

FAKE="$T/fake"; mkdir -p "$FAKE/bin"; echo '[]' > "$FAKE/agents.json"
cat > "$FAKE/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == agents ]]; then
  [[ -n "\${FAKE_FAIL_AGENTS:-}" ]] && exit 1
  [[ "\$*" == *--all* ]] && { cat "$FAKE/agents.json"; exit 0; }
  jq '[.[] | select(.state != "stopped")]' "$FAKE/agents.json"; exit 0
fi
[[ -n "\${FAKE_FAIL_BG:-}" && "\$*" == *"--session-id"* ]] && exit 1
printf '%s\t%s\n' "\$PWD" "\$*" >> "$FAKE/claude.log"
EOF
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "pr view" ]] && { cat "$FAKE/pr-\$3" 2>/dev/null || echo OPEN; exit 0; }
exit 1
EOF
chmod +x "$FAKE/bin/claude" "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH" SHEPHERD_FLEET_INTERVAL=1

A="$T/a"; git init -q -b main "$A"; git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
P="$T/plan.md"
cat > "$P" <<'EOF'
# Proposal: test
## Slices
### slice-1: first
- **Depends on:** none
- **Files:** `a.sh`
### slice-2: second
- **Depends on:** slice-1
- **Files:** `b.sh`
### slice-3: overlaps one
- **Depends on:** none
- **Files:** `a.sh`
### slice-4: free
- **Depends on:** none
- **Files:** `c.sh`, `d.sh` (new)
### Notes
- **Files:** `z.sh`
## Open questions
EOF

rec="$A/.git/shepherd/_fleet/plan.json"
wt() { jq -r --arg n "$1" '.slices[$n].worktree' "$rec"; }
sess() { jq -r --arg n "$1" '.slices[$n].session' "$rec"; }
agents() { jq -n --argjson s "$1" '[$s | to_entries[] | {sessionId: .key, state: .value, status: "idle"}]' > "$FAKE/agents.json"; }
state() { local w; w=$(wt "$1"); shift; sh "$w" init >/dev/null; sh "$w" set "$@"; }
order() { sh "$A" fleet status --json | jq -c '[.[].slice]'; }

out=$(sh "$A" fleet start "$P" --max 3)
ok "start dispatches free slices only" '[[ "$(cut -f2 "$FAKE/claude.log" | grep -o "#slice-[0-9]" | xargs)" == "#slice-1 #slice-4" ]]'
ok "session runs in its worktree" 'grep -q "^$(wt 1)	--bg -n shepherd-plan-slice-1 --session-id $(sess 1) /shepherd:run $P#slice-1$" "$FAKE/claude.log"'
ok "record maps slice to branch, worktree, session" '[[ "$(jq -r ".slices[\"1\"] | [.base, .branch] | join(\" \")" "$rec")" == "main fleet/plan/slice-1" && -d "$(wt 1)" && -n "$(sess 4)" ]]'
ok "parses depends and every backticked file" '[[ "$(jq -c "[.slices[\"2\"].depends, .slices[\"4\"].files]" "$rec")" == '"'"'[[1],["c.sh","d.sh"]]'"'"' ]]'
ok "overlap and unmet dependency stay pending" '[[ "$(jq -r ".slices[\"2\"].session, .slices[\"3\"].session" "$rec" | xargs)" == "null null" ]]'

git -C "$(wt 1)" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
agents "{\"$(sess 1)\":\"done\",\"$(sess 4)\":\"done\"}"
state 1 phase=done pr:=11
sh "$A" fleet next >/dev/null
ok "stacked slice starts on its ready dependency" '[[ "$(jq -r ".slices[\"2\"].base" "$rec")" == fleet/plan/slice-1 && "$(git -C "$(wt 2)" rev-parse HEAD)" == "$(git -C "$(wt 1)" rev-parse HEAD)" ]]'
ok "overlap with an unmerged slice still waits" '[[ "$(jq -r ".slices[\"3\"].session" "$rec")" == null ]]'

agents "{\"$(sess 1)\":\"done\",\"$(sess 4)\":\"done\",\"$(sess 2)\":\"blocked\"}"
state 4 phase=waiting_user question=which
ok "status ranks ready, input, stalled, pending" '[[ "$(order)" == "[1,4,2,3]" ]]'
ok "status shows the question" '[[ "$(sh "$A" fleet status --json | jq -r ".[] | select(.slice == 4) | .question")" == which ]]'

(sleep 2; sh "$(wt 4)" set phase=implement) &
w=$(sh "$A" fleet wait --timeout 10); wait
ok "wait reports the change" '[[ "$w" == "slice-4: input/waiting_user -> running/implement" ]]'

echo MERGED > "$FAKE/pr-11"
sh "$A" fleet next >/dev/null
ok "next starts a slice once the overlap merged" '[[ "$(jq -r ".slices[\"3\"].base" "$rec")" == main ]]'

echo "use option b" > "$T/answer.txt"
: > "$FAKE/claude.log"
sh "$A" fleet answer 4 "$T/answer.txt" >/dev/null
ok "answer stops, then resumes in the worktree" '[[ "$(cut -f2 "$FAKE/claude.log" | head -1)" == "stop $(sess 4 | cut -c1-8)" ]] && grep -q "^$(wt 4)	--bg --resume $(sess 4) use option b$" "$FAKE/claude.log"'
: > "$FAKE/claude.log"
ok "answer fails when claude agents fails, without resuming" '! FAKE_FAIL_AGENTS=1 sh "$A" fleet answer 4 "$T/answer.txt" 2>/dev/null && ! grep -q -- "--resume" "$FAKE/claude.log"'
ok "stop fails when claude agents fails" '! FAKE_FAIL_AGENTS=1 sh "$A" fleet stop >/dev/null 2>&1'
ok "self names the slice of its worktree" '[[ "$(sh "$(wt 2)" fleet self | jq -c "[.slug, .slice, .base]")" == '"'"'["plan",2,"fleet/plan/slice-1"]'"'"' ]]'
ok "self fails outside a slice worktree" '! sh "$A" fleet self >/dev/null 2>&1'
hook() { jq -n --arg cwd "$1" '{cwd: $cwd}' | bash "$HOOKS/$2"; }
sh "$A" fleet lead dispatching
ok "stop hook blocks an active lead phase" 'hook "$A" stop.sh | jq -e ".decision == \"block\" and (.reason | test(\"lead phase is .dispatching.\"))" >/dev/null'
hook "$A" stop.sh >/dev/null; hook "$A" stop.sh >/dev/null
ok "stop hook gives up after the cap" '[[ -z "$(hook "$A" stop.sh)" ]]'
sh "$A" fleet lead waiting_fleet
ok "stop hook lets waiting_fleet end the turn" '[[ -z "$(hook "$A" stop.sh)" ]]'
ok "session start names the active lead" 'hook "$A" session-start.sh | jq -r .hookSpecificOutput.additionalContext | grep -q "shepherd lead is active .* fleet .plan. (phase: waiting_fleet)"'
sh "$A" fleet lead done
ok "a done lead is silent" '[[ -z "$(hook "$A" stop.sh)" && -z "$(hook "$A" session-start.sh)" ]]'
ok "lead refuses an unknown phase" '! sh "$A" fleet lead planning 2>/dev/null'
ok "start refuses a second run" '! sh "$A" fleet start "$P" 2>/dev/null'

ok "status fails without a fleet record" '(cd "$T" && git init -q -b main b) && ! out=$(sh "$T/b" fleet status 2>/dev/null) && [[ -z "$out" ]]'
ok "status fails when claude agents fails" '! FAKE_FAIL_AGENTS=1 sh "$A" fleet status >/dev/null 2>&1'

C="$T/c"; git init -q -b main "$C"; git -C "$C" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '### slice-1: x\n- **Depends on:** slice-9\n- **Files:** `a`\n' > "$T/bad.md"
ok "unknown dependency refused, no record" '! sh "$C" fleet start "$T/bad.md" 2>/dev/null && [[ ! -e "$C/.git/shepherd/_fleet/bad.json" ]]'
printf '### slice-1: x\n- **Depends on:** none\n- **Files:** `a`\n' > "$T/one.md"
ok "failed session start leaves no worktree or branch" '! FAKE_FAIL_BG=1 sh "$C" fleet start "$T/one.md" 2>/dev/null && [[ $(git -C "$C" worktree list | wc -l) -eq 1 ]] && [[ -z "$(git -C "$C" branch --list "fleet/*")" ]]'
git -C "$C" switch -q -c feat/t
ok "init --target sets the PR base" '[[ "$(jq -r .target_branch "$(sh "$C" init --target fleet/plan/slice-1)/state.json")" == fleet/plan/slice-1 ]]'
git -C "$C" switch -q main
ok "next succeeds after a failed start" 'sh "$C" fleet next | grep -q "dispatched slice-1"'

echo "pass=$pass fail=$fail"; rm -rf "$T"
(( fail == 0 ))
