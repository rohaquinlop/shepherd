#!/usr/bin/env bash
# Push gates on a throwaway repo with a local bare origin: the PreToolUse hook
# (hooks/pre-push.sh) and the git gate `shepherd init` installs.
# usage: bash tests/hooks.sh [shepherd checkout]   (default: this checkout)
set -u
REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; CLI="$REPO/scripts/shepherd.sh"; HOOKS="$REPO/hooks"
T=$(cd "$(mktemp -d)" && pwd -P); pass=0; fail=0
ok() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q "${@:2}"; }

git init -q --bare "$T/origin.git"
git init -q -b main "$T/r"; commit "$T/r" --allow-empty -m init
git -C "$T/r" remote add origin "$T/origin.git"
mkdir "$T/r/.husky"
for h in pre-push pre-commit; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/repo-hook.log"\n' "$h" "$T" >"$T/r/.husky/$h"; chmod +x "$T/r/.husky/$h"
done
git -C "$T/r" config core.hooksPath .husky
git -C "$T/r" add .husky; commit "$T/r" -m husky; git -C "$T/r" push -q origin main
: >"$T/repo-hook.log"
W="$T/wt"; git -C "$T/r" worktree add -q -b feat/x "$W" main
(cd "$W" && bash "$CLI" init >/dev/null)
commit "$W" --allow-empty -m a

probe() { jq -n --arg c "$1" --arg d "$W" '{tool_name:"Bash", tool_input:{command:$c}, cwd:$d}' | bash "$HOOKS/pre-push.sh"; }
denied() { probe "$1" | grep -q '"deny"'; }
pushes() { (cd "$W" && eval "$1") >/dev/null 2>&1; }
clear_head() { (cd "$W" && bash "$CLI" set "cleared_tree=$(git rev-parse 'HEAD^{tree}')"); }

# 1. uncleared tree: hook denies and git rejects every shape
shapes=(
  $'echo ok\ngit push origin feat/x'
  'bash -c "git push origin feat/x"'
  'command git push origin feat/x'
  '`git push origin feat/x`'
  'env FOO=1 git push origin feat/x'
  'git push origin +feat/x'
)
for c in "${shapes[@]}"; do
  ok "hook denies uncleared: ${c//$'\n'/\\n}" 'denied "$c"'
  ok "git rejects uncleared: ${c//$'\n'/\\n}" '! pushes "$c"'
done
ok "origin has no feat/x" '! git -C "$T/origin.git" rev-parse -q --verify refs/heads/feat/x >/dev/null'
ok "main worktree keeps its hooksPath" '[[ "$(git -C "$T/r" config core.hooksPath)" == .husky ]]'

# 2. cleared tree: force, --no-verify, and hooksPath overrides still denied
clear_head
deep='git push origin feat/x'; for _ in 1 2 3 4 5 6; do deep="bash -c $(printf %q "$deep")"; done
for c in 'git push --force origin feat/x' 'git push -f origin feat/x' 'git push -uf origin feat/x' \
  'git push origin +feat/x' 'git push --force-with-lease origin feat/x' 'git push --no-verify origin feat/x' \
  'git -c core.hooksPath=/dev/null push origin feat/x' 'GIT_CONFIG_COUNT=1 git push origin feat/x' \
  $'export GIT_CONFIG_PARAMETERS=x\ngit push origin feat/x' 'if true; then git push --no-verify origin feat/x; fi' \
  '{ git push -f origin feat/x; }' '! git push -f origin feat/x' 'echo origin | xargs -n 1 git push -f' \
  'eval "git push --no-verify origin feat/x"' 'nohup git push -f origin feat/x' 'timeout -s KILL 5 git push -f' \
  'while true; do gh pr merge 1; done' 'function f { git push -f origin feat/x; }; f' 'exec -a g git push -f' \
  '$(command -v git) push --no-verify origin feat/x' 'g=git; $g push --no-verify origin feat/x' \
  'GIT_CONFIG_COUNT=1 $(command -v git) push origin feat/x' 'echo $(echo ")") ; git push -f origin feat/x' \
  "$deep" 'gh -R o/r pr merge 1' 'gh -R o/r api -X PUT repos/o/r/pulls/1/merge'; do
  ok "hook denies: ${c//$'\n'/\\n}" 'denied "$c"'
done
for c in 'grep -n hooksPath hooks/pre-push.sh' 'grep GIT_CONFIG .husky/pre-push' 'git commit -m "push --no-verify"'; do
  ok "hook allows: $c" '! denied "$c"'
done
ok "push then rm -f is not a force push" '! denied "git push origin feat/x && rm -f x"'
ok "cleared push passes" 'pushes "git push -u origin feat/x"'
ok "git gate chains to the repo pre-push" 'grep -q "^pre-push origin" "$T/repo-hook.log"'
commit "$W" --amend --allow-empty -m b; clear_head
ok "git rejects a rewrite of a cleared tree" '! pushes "git push --force origin feat/x"'

# 3. merges
ok "hook denies gh pr merge on line 2" 'denied $'"'"'echo ok\ngh pr merge 1'"'"''
ok "hook denies gh api PUT merge" 'denied "gh api -X PUT repos/o/r/pulls/1/merge"'
ok "hook allows gh api GET merge" '! denied "gh api repos/o/r/pulls/1/merge"'

# 4. no jq on PATH
mkdir "$T/bin"; for b in cat dirname git; do ln -s "$(command -v "$b")" "$T/bin/$b"; done
nojq() { jq -n --arg c "$2" '{tool_input:{command:$c}}' | (cd "$1" && PATH="$T/bin" "$BASH" "$HOOKS/pre-push.sh" 2>/dev/null); }
ok "no jq: push denied" 'nojq "$W" "git push origin feat/x"; [[ $? == 2 ]]'
ok "no jq: other command passes" 'nojq "$W" "ls"'
ok "no jq: push on a branch without state passes" 'nojq "$T/r" "git push origin main"'
ok "no jq: a path naming merge does not deny ls" \
  'jq -n "{tool_input:{command:\"ls\"}, cwd:\"/x/fix-merge\", transcript_path:\"/push\"}" | (cd "$W" && PATH="$T/bin" "$BASH" "$HOOKS/pre-push.sh")'

# 4b. the pre-push stub runs a copy of the gate, not the plugin path
GH="$T/r/.git/worktrees/wt/shepherd/_githooks"
ok "gate copy installed, stub has no plugin path" '[[ -f "$GH/gate/hooks/git-pre-push.sh" && -f "$GH/gate/lib/state.sh" ]] && ! grep -q "$REPO" "$GH/pre-push"'

# 5. other hooks chain; a branch without state passes the git gate
: >"$T/repo-hook.log"
commit "$W" --allow-empty -m c
ok "repo pre-commit still runs in the gated worktree" 'grep -q "^pre-commit" "$T/repo-hook.log"'
git -C "$W" switch -q -c other
ok "stateless branch push passes" 'pushes "git push origin other" && grep -q "^pre-push origin" "$T/repo-hook.log"'

W2="$T/wt2"; git -C "$W" worktree add -q -b feat/y "$W2" main
(cd "$W2" && bash "$CLI" init >/dev/null 2>&1)
ok "a worktree added from a gated one gets its own gate" \
  '[[ "$(git -C "$W2" config --worktree core.hooksPath)" == "$T/r/.git/worktrees/wt2/shepherd/_githooks" ]]'

echo "pass=$pass fail=$fail"; git -C "$T/r" worktree remove --force "$W"; git -C "$T/r" worktree remove --force "$W2"; rm -rf "$T"
(( fail == 0 ))
