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
echo "\${CLAUDE_CONFIG_DIR:-unset}" >> "$FAKE/cfg.log"
[[ -n "\${FAKE_NO_CLAUDE:-}" ]] && { echo called >> "$FAKE/forbidden.log"; exit 1; }
[[ "\$1" == logs ]] && { printf '%s\t%s\n' "\$PWD" "\$*" >> "$FAKE/claude.log"; seq 300; exit 0; }
if [[ "\$1" == agents ]]; then
  [[ -n "\${FAKE_FAIL_AGENTS:-}" ]] && exit 1
  [[ "\$*" == *--all* ]] && { cat "$FAKE/agents.json"; exit 0; }
  jq '[.[] | select(.state != "stopped")]' "$FAKE/agents.json"; exit 0
fi
[[ -n "\${FAKE_FAIL_BG:-}" && "\$1 \$2" == "--bg -n" ]] && exit 1
printf '%s\t%s\n' "\$PWD" "\$*" >> "$FAKE/claude.log"
if [[ "\$1 \$2" == "--bg -n" ]]; then
  [[ -n "\${FAKE_NO_JOB:-}" ]] && { echo "Starting background service…"; exit 0; }
  id=\$(uuidgen | tr '[:upper:]' '[:lower:]')
  jq --arg id "\$id" --arg name "\$3" --argjson t "\$(date +%s)000" '. + [{id: \$id[:8], kind: "background", sessionId: \$id, name: \$name, startedAt: \$t, state: "working"}]' "$FAKE/agents.json" > "$FAKE/agents.tmp" && mv "$FAKE/agents.tmp" "$FAKE/agents.json"
  echo "backgrounded · \${id:0:8} · \$3"
fi
EOF
cat > "$FAKE/bin/gh" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "pr view" ]] && { cat "$FAKE/pr-\$3" 2>/dev/null || echo OPEN; exit 0; }
exit 1
EOF
chmod +x "$FAKE/bin/claude" "$FAKE/bin/gh"
export PATH="$FAKE/bin:$PATH" SHEPHERD_FLEET_INTERVAL=1 SHEPHERD_FLEET_START_TIMEOUT=1 CLAUDE_CODE_SESSION_ID=lead-1 CLAUDE_CONFIG_DIR="$T/cfg"
claude() { echo called >> "$FAKE/function.log"; }
export -f claude

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
plan_sed() { sed -i.bak "$1" "$P" && rm "$P.bak"; }
order() { sh "$A" fleet status --json | jq -c '[.[].slice]'; }

out=$(sh "$A" fleet start "$P" --max 3)
export CLAUDE_CONFIG_DIR="$T/other"
ok "start dispatches free slices only" '[[ "$(cut -f2 "$FAKE/claude.log" | grep -o "#slice-[0-9]" | xargs)" == "#slice-1 #slice-4" ]]'
ok "session runs in its worktree" 'grep -q "^$(wt 1)	--bg -n shepherd-plan-slice-1 /shepherd:run $P#slice-1$" "$FAKE/claude.log"'
ok "record holds the real session id" '[[ "$(sess 1)" == "$(jq -r ".[] | select(.name == \"shepherd-plan-slice-1\") | .sessionId" "$FAKE/agents.json")" && "$(sh "$A" fleet status --json | jq -r ".[] | select(.slice == 1) | .category")" == running ]]'
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
ok "status rows carry the fleet target" '[[ "$(sh "$A" fleet status --json | jq -r "[.[].target] | unique | join(\",\")")" == main ]]'
ok "status shows the question" '[[ "$(sh "$A" fleet status --json | jq -r ".[] | select(.slice == 4) | .question")" == which ]]'

ok "the first wait reports a slice already waiting" '[[ "$(sh "$A" fleet wait --timeout 0)" == *"slice-4: new/- -> input/waiting_user"* ]]'
(sleep 1; sh "$(wt 4)" set phase=implement) &
w=$(sh "$A" fleet wait --timeout 3); wait
ok "wait stays quiet when a slice goes back to running" '[[ "$w" == "no fleet change after 3s" ]]'

sh "$(wt 4)" set phase=waiting_user
ok "a change between two waits is reported at once" '[[ "$(sh "$A" fleet wait --timeout 0)" == "slice-4: running/implement -> input/waiting_user" ]]'
ok "an unchanged fleet times out" '! sh "$A" fleet wait --timeout 0 >/dev/null'
sh "$(wt 4)" set phase=implement; sh "$A" fleet wait --timeout 0 >/dev/null
sh "$(wt 4)" set phase=waiting_ci
ok "a phase change inside running is reported" '[[ "$(sh "$A" fleet wait --timeout 0)" == "slice-4: running/implement -> running/waiting_ci" ]]'
sh "$(wt 4)" set phase=implement; sh "$A" fleet wait --timeout 0 >/dev/null
echo MERGED > "$FAKE/pr-11"
sh "$A" fleet next >/dev/null
ok "next starts a slice once the overlap merged" '[[ "$(jq -r ".slices[\"3\"].base" "$rec")" == main ]]'
agents "{\"$(sess 1)\":\"done\",\"$(sess 4)\":\"done\",\"$(sess 2)\":\"blocked\",\"$(sess 3)\":\"busy\"}"
ok "wait skips the lead's own dispatch" '[[ "$(sh "$A" fleet wait --timeout 0)" != *slice-3* ]]'
printf '### slice-5: added\n- **Depends on:** slice-3\n- **Files:** `e.sh`\n' >> "$P"
sh "$A" fleet next >/dev/null
ok "next adds a slice appended by a re-plan" '[[ "$(jq -c ".slices[\"5\"] | [.title, .depends]" "$rec")" == '"'"'["added",[3]]'"'"' && "$(jq -r ".slices[\"3\"].session" "$rec")" != null ]]'
plan_sed 's/^### slice-5: added$/### slice-5: renamed/'
sh "$A" fleet next >/dev/null
ok "next takes an edit to a slice that has not started" '[[ "$(jq -r ".slices[\"5\"].title" "$rec")" == renamed ]]'
plan_sed 's/^- \*\*Depends on:\*\* slice-3$/- **Depends on:** slice-3, slice-9/'
ok "next refuses an edit to an unknown dependency" '! sh "$A" fleet next 2>/dev/null && [[ "$(jq -c ".slices[\"5\"].depends" "$rec")" == "[3]" ]]'
plan_sed 's/^- \*\*Depends on:\*\* slice-3, slice-9$/- **Depends on:** slice-3/'
printf '### slice-6: bad\n- **Depends on:** slice-9\n- **Files:** `f.sh`\n' >> "$P"
ok "next refuses a re-plan with an unknown dependency" '! sh "$A" fleet next 2>/dev/null && [[ "$(jq -r ".slices[\"6\"]" "$rec")" == null ]]'
plan_sed '/^### slice-6/,$d'
mv "$P" "$P.away"
ok "next fails when the proposal is gone" '! sh "$A" fleet next 2>/dev/null'
mv "$P.away" "$P"

echo "use option b" > "$T/answer.txt"
: > "$FAKE/claude.log"
sh "$A" fleet answer 4 "$T/answer.txt" >/dev/null
ok "answer stops, then resumes in the worktree" '[[ "$(cut -f2 "$FAKE/claude.log" | head -1)" == "stop $(sess 4 | cut -c1-8)" ]] && grep -q "^$(wt 4)	--bg --resume $(sess 4) use option b$" "$FAKE/claude.log"'
: > "$FAKE/claude.log"
ok "answer fails when claude agents fails, without resuming" '! FAKE_FAIL_AGENTS=1 sh "$A" fleet answer 4 "$T/answer.txt" 2>/dev/null && ! grep -q -- "--resume" "$FAKE/claude.log"'
sh "$(wt 4)" set phase=waiting_user; sh "$A" fleet wait --timeout 0 >/dev/null
sh "$A" fleet answer 4 "$T/answer.txt" >/dev/null
ok "the answered question stays quiet" '! sh "$A" fleet wait --timeout 0 >/dev/null'
sh "$(wt 4)" set question=again
ok "a new question after an answer wakes the lead" '[[ "$(sh "$A" fleet wait --timeout 0)" == "slice-4: input/waiting_user -> input/waiting_user" ]]'
ok "status takes --fleet after the subcommand" 'sh "$A" fleet status --fleet plan --json | jq -e "length > 0" >/dev/null'
ok "stop fails when claude agents fails" '! FAKE_FAIL_AGENTS=1 sh "$A" fleet stop >/dev/null 2>&1'
: > "$FAKE/claude.log"
ok "logs reads the recorded session, last 200 lines by default" '[[ "$(sh "$A" fleet logs 1 | wc -l | xargs)" == 200 && "$(sh "$A" fleet logs 1 --tail 5 | head -1)" == 296 ]] && [[ "$(cut -f2 "$FAKE/claude.log" | sort -u)" == "logs $(sess 1 | cut -c1-8)" ]]'
ok "attach prints the command with the recorded config" '[[ "$(sh "$A" fleet attach 1)" == "CLAUDE_CONFIG_DIR=$T/cfg claude attach $(sess 1 | cut -c1-8)" ]]'
ok "status prints the recorded config dir" '[[ "$(sh "$A" fleet status | head -1)" == "config_dir $T/cfg" ]]'
ok "every claude call used the recorded config, never the shell function" '[[ "$(sort -u "$FAKE/cfg.log")" == "$T/cfg" && ! -e "$FAKE/function.log" ]]'
ok "self names the slice of its worktree" '[[ "$(sh "$(wt 2)" fleet self | jq -c "[.slug, .slice, .base]")" == '"'"'["plan",2,"fleet/plan/slice-1"]'"'"' ]]'
ok "self fails outside a slice worktree" '! sh "$A" fleet self >/dev/null 2>&1'
sh "$A" fleet base 2 main
ok "base records a retargeted slice" '[[ "$(jq -r ".slices[\"2\"].base" "$rec")" == main ]]'
ok "base refuses an unknown slice" '! sh "$A" fleet base 9 main 2>/dev/null'
hook() { jq -n --arg cwd "$1" --arg s "${3:-lead-1}" '{cwd: $cwd, session_id: $s}' | bash "$HOOKS/$2"; }
sh "$A" fleet lead dispatching
ok "stop hook leaves other sessions in the lead checkout alone" '[[ -z "$(hook "$A" stop.sh other)" ]]'
ok "stop hook blocks an active lead phase" 'hook "$A" stop.sh | jq -e ".decision == \"block\" and (.reason | test(\"lead phase is .dispatching.\"))" >/dev/null'
hook "$A" stop.sh >/dev/null; hook "$A" stop.sh >/dev/null
ok "stop hook gives up after the cap" '[[ -z "$(hook "$A" stop.sh)" ]]'
sh "$A" fleet lead waiting_fleet
ok "stop hook lets waiting_fleet end the turn" '[[ -z "$(hook "$A" stop.sh)" ]]'
sh "$A" fleet lead dispatching; mkdir "$rec.lock"; echo $$ > "$rec.lock/pid"
ok "stop hook names a locked record instead of blocking" 'hook "$A" stop.sh | jq -e ".systemMessage | test(\"locked\")" >/dev/null'
rm -rf "$rec.lock"; sh "$A" fleet lead waiting_fleet
ok "session start is silent for another session" '[[ -z "$(hook "$A" session-start.sh other)" ]]'
ok "session start names the active lead" 'hook "$A" session-start.sh | jq -r .hookSpecificOutput.additionalContext | grep -q "shepherd lead is active .* fleet .plan. (phase: waiting_fleet)"'
sh "$A" fleet lead done
ok "a done lead is silent" '[[ -z "$(hook "$A" stop.sh)" && -z "$(hook "$A" session-start.sh)" ]]'
ok "lead refuses an unknown phase" '! sh "$A" fleet lead planning 2>/dev/null'
ok "lead refuses outside a Claude Code session" '! CLAUDE_CODE_SESSION_ID= sh "$A" fleet lead waiting_fleet 2>/dev/null'
sh "$A" fleet lead waiting_fleet; sh "$A" fleet base 2 main; pids=()
for i in 1 2 3 4 5; do sh "$A" fleet base 2 "b$i" & pids+=($!); sh "$A" fleet lead done & pids+=($!); done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
ok "parallel record writes keep each other" '(( rc == 0 )) && [[ "$(jq -r ".lead.phase, .slices[\"2\"].base" "$rec" | xargs)" == "done b"[1-5] && -z "$(ls "$rec".* 2>/dev/null)" ]]'
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
echo '[{"sessionId":"stale","name":"shepherd-one-slice-1","startedAt":1,"state":"done"}]' > "$FAKE/agents.json"
ok "no new job within the timeout leaves no record, worktree, or branch" '! FAKE_NO_JOB=1 sh "$C" fleet next 2>/dev/null && [[ "$(jq -r ".slices[\"1\"].session" "$C/.git/shepherd/_fleet/one.json")" == null && $(git -C "$C" worktree list | wc -l) -eq 1 && -z "$(git -C "$C" branch --list "fleet/*")" ]]'
ok "next succeeds after a failed start" 'sh "$C" fleet next | grep -q "dispatched slice-1"'
: > "$FAKE/cfg.log"; jq 'del(.config_dir)' "$C/.git/shepherd/_fleet/one.json" > "$T/one.json" && mv "$T/one.json" "$C/.git/shepherd/_fleet/one.json"
ok "a record without config_dir uses the current env" 'CLAUDE_CONFIG_DIR="$T/env" sh "$C" fleet status >/dev/null && [[ "$(sort -u "$FAKE/cfg.log")" == "$T/env" ]]'

repo() { git init -q -b main "$1"; git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }
picked() { jq -c '[.slices | to_entries[] | select(.value.session != null) | {k: .key, b: .value.base}]' "$1/.git/shepherd/_fleet/plan.json"; }
slice_done() { (cd "$(jq -r '.slices["1"].worktree' "$1/.git/shepherd/_fleet/plan.json")" && bash "$CLI" init >/dev/null && bash "$CLI" set phase=done pr:=21); }
F="$T/f"; repo "$F"; sh "$F" fleet start "$P" --max 3 >/dev/null; slice_done "$F"; sh "$F" fleet next >/dev/null

E="$T/e"; repo "$E"
erec="$E/.git/shepherd/_fleet/plan.json"
ewt() { jq -r --arg n "$1" '.slices[$n].worktree' "$erec"; }
export FAKE_NO_CLAUDE=1
eout=$(sh "$E" fleet start "$P" --dispatch external --max 3)
ok "external start prints one line per free slice and runs no claude" '[[ "$(cut -f1 <<<"$eout" | xargs)" == "slice-1 slice-4" ]] && grep -qx "slice-1	$(ewt 1)	/shepherd:run $P#slice-1" <<<"$eout" && [[ ! -e "$FAKE/forbidden.log" && -d "$(ewt 1)" ]]'
ok "external slices are recorded and running" '[[ "$(jq -r "[.slices[\"1\"].dispatch, .slices[\"4\"].dispatch] | join(\" \")" "$erec")" == "external external" && "$(sh "$E" fleet status --json | jq -r "[.[] | select(.category == \"running\") | .slice] | join(\",\")")" == 1,4 ]]'
ok "answer refuses an unbound external slice" '! sh "$E" fleet answer 1 "$T/answer.txt" >/dev/null 2>&1'
sh "$E" fleet bind 1 app-session-1
ok "bind records the session ref" '[[ "$(jq -r ".slices[\"1\"].session" "$erec")" == app-session-1 ]] && ! sh "$E" fleet bind 3 x 2>/dev/null'
(cd "$(ewt 1)" && bash "$CLI" init >/dev/null && bash "$CLI" set phase=waiting_user question=which)
ok "external status follows the state file" '[[ "$(sh "$E" fleet status --json | jq -r ".[] | select(.slice == 1) | .category")" == input ]]'
ok "external answer prints the answer instead of resuming" '[[ "$(sh "$E" fleet answer 1 "$T/answer.txt" | tail -1)" == "use option b" ]]'
ok "logs and attach refuse an external slice" '! sh "$E" fleet logs 1 2>/dev/null && ! sh "$E" fleet attach 1 2>/dev/null'
ok "stop names external slices and runs no claude" '[[ "$(sh "$E" fleet stop | wc -l | xargs)" == 2 ]]'
slice_done "$E"
sh "$E" fleet next --dispatch external >/dev/null
ok "both modes pick the same slices" '[[ "$(picked "$E")" == "$(picked "$F")" && "$(picked "$F")" == *slice-1* && ! -e "$FAKE/forbidden.log" ]]'
unset FAKE_NO_CLAUDE
ok "launch runs an unbound external slice in the CLI" 'sh "$E" fleet launch 4 | grep -q "dispatched slice-4" && [[ "$(jq -r ".slices[\"4\"].dispatch" "$erec")" == null ]] && ! sh "$E" fleet launch 1 2>/dev/null'
: > "$FAKE/claude.log"
ok "logs refuses a bad --tail before calling claude" '! sh "$E" fleet logs 4 --tail x 2>/dev/null && ! grep -q "	logs " "$FAKE/claude.log"'

echo "pass=$pass fail=$fail"; rm -rf "$T"
(( fail == 0 ))
