#!/usr/bin/env bash
# Review economy on a throwaway repo with a local bare origin: slice-only
# source.md, bundle context diff, reviewer model choice, post-PR budget.
# usage: bash tests/review.sh [shepherd checkout]   (default: this checkout)
set -u
REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"; CLI="$REPO/scripts/shepherd.sh"
T=$(cd "$(mktemp -d)" && pwd -P); pass=0; fail=0
ok() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
commit() { git -C "$R" -c user.name=t -c user.email=t@t commit -q "$@"; }
sh() { (cd "$R" && bash "$CLI" "$@"); }
model() { sh review-start "$@" 2>/dev/null | sed -n 's/^model: //p'; }
config() { mkdir -p "$R/.claude"; echo "$1" >"$R/.claude/shepherd.json"; }

R="$T/r"
git init -q --bare "$T/origin.git"
git init -q -b main "$R"; commit --allow-empty -m init
git -C "$R" remote add origin "$T/origin.git"; git -C "$R" push -q origin main
git -C "$R" switch -q -c feat/x
sh init --target main >/dev/null 2>&1

# 1. source.md for a slice keeps only that slice
cat >"$T/p.md" <<'EOF'
# Proposal: two slices

- **Verdict:** feasible

## Idea

idea text

## Rules that apply

rule text

## Impact map

impact text

## Options

options text

**Recommendation:** O1.

## Decisions

decision text

## Slices

### slice-1: first

slice one text

### slice-2: second

slice two text

## Next session

next text
EOF
src=$(sh source "$T/p.md#slice-1")
for want in "- **Verdict:** feasible" "rule text" "impact text" "**Recommendation:** O1." "decision text" "### slice-1: first" "slice one text"; do
  ok "source keeps: $want" 'grep -qF -- "$want" "$src"'
done
for drop in "### slice-2:" "slice two text" "idea text" "options text" "next text"; do
  ok "source drops: $drop" '! grep -qF -- "$drop" "$src"'
done
ok "source refuses a missing slice" '! sh source "$T/p.md#slice-9" 2>/dev/null'
sh source "$T/p.md" >/dev/null
ok "source without anchor copies the file" 'cmp -s "$T/p.md" "$src"'
sed -e '/^## Slices$/d' -e 's/^## Next session$/## Decisions/' "$T/p.md" >"$T/q.md"
sh source "$T/q.md#slice-1" >/dev/null
ok "slices under a kept section: other slice dropped" '! grep -qF "slice two text" "$src" && grep -qF "slice one text" "$src" && grep -qF "next text" "$src"'
sh source "$T/p.md#slice-1" >/dev/null

# 2. bundle: slice-only source; context diff omitted or capped
seq 1 50 >"$R/a.txt"; git -C "$R" add a.txt; commit -m a
sh policy-base add >/dev/null
b=$(sh bundle)
ok "bundle has no other slice" '! grep -qF "### slice-2:" "$b" && grep -qF "### slice-1: first" "$b"'
sh set "previous_candidate=$(git -C "$R" rev-parse main)"
echo b >"$R/b.txt"; git -C "$R" add b.txt; commit -m b
b=$(sh bundle)
ok "context diff omitted when the new diff covers the branch" '! grep -q "context only" "$b"'
sh set "previous_candidate=$(git -C "$R" rev-parse HEAD)"
echo c >"$R/c.txt"; git -C "$R" add c.txt; commit -m c
config '{"bundle_context_lines": 5}'
b=$(sh bundle)
ok "context diff capped" 'grep -q "context only" "$b" && grep -q "context diff cut at 5 of" "$b"'
sh policy-base remove

# 3. reviewer model: Opus only after an escalation
ok "escalate refused on call 1" '! sh review-start --escalate x >/dev/null 2>&1 && [[ "$(sh get reviews)" == 0 ]]'
ok "call 1 default" '[[ "$(model)" == default ]]'
ok "call 2 sonnet" '[[ "$(model)" == sonnet ]]'
ok "call 3 opus after escalate" '[[ "$(model --escalate "DECISION: api shape")" == opus ]]'
ok "escalation recorded" 'grep -q "model opus" "$(sh dir)/decisions.md" && grep -q "escalated: DECISION: api shape" "$(sh dir)/decisions.md"'
ok "verify default" '[[ "$(model --verify)" == default ]]'
ok "no Opus without escalation" '[[ $(grep -c "model opus" "$(sh dir)/decisions.md") -eq 1 ]]'
echo plan >"$(sh dir)/plan.md"; sh policy-base add >/dev/null
ok "plan call 1 default" '[[ "$(model --plan)" == default ]]'
ok "plan call 2 opus after escalate" '[[ "$(model --plan --escalate "design gap")" == opus ]]'
sh policy-base remove

# 4. post-PR budget
sh set "pr:=7" "round_reopenable:=true"
sh review-round --reason "CI round" >/dev/null
ok "post-PR budget defaults to 1" '[[ "$(sh get max_reviews)" == 1 ]]'
ok "post-PR call default" '[[ "$(model)" == default ]]'
config '{"max_reviews_after_pr": 2}'
sh review-round --user --reason "user" >/dev/null
ok "post-PR budget from config" '[[ "$(sh get max_reviews)" == 2 ]]'

# 5. the run skill names Opus only under the escalation rule
ok "skill: opus only in escalation" '[[ "$(grep -ci opus "$REPO/skills/run/SKILL.md")" == 1 ]] && grep -i opus "$REPO/skills/run/SKILL.md" | grep -q "only way"'
ok "policy-base left no worktree" '[[ $(git -C "$R" worktree list | wc -l) -eq 1 ]]'
git -C "$R" switch -q -c feat/y; sh init --pr 9 >/dev/null 2>&1
ok "init --pr uses the post-PR budget" '[[ "$(sh get max_reviews)" == 2 ]]'

echo "pass=$pass fail=$fail"; rm -rf "$T"
(( fail == 0 ))
