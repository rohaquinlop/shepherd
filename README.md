# shepherd

A Claude Code plugin that drives one change from an issue to a merge-ready PR, and stops only for decisions that need you.

```
/shepherd:run 123
```

study → brief → implement → targeted checks → **fresh read-only review (max 3)** → push → CI → triage comments → merge-ready

The design follows the PR workflow in [pydantic-ai](https://github.com/pydantic/pydantic-ai) (`.agents/skills/pushing-commits-to-the-repo`): one agent writes the code, a separate agent with no chat history reviews it against the target branch's rules, and both iterate locally before CI and humans see the change.

## What runs where

| Part | Role |
|---|---|
| `skills/run` | The playbook. Claude follows it in your main session and writes the code there. |
| `agents/reviewer` | A fresh reviewer with only `Read`, `Grep`, and `Glob`. It reads a review bundle and the target branch's rules, then returns findings or `current at <sha>`. |
| `scripts/shepherd.sh` | State, decision log, review budget, review bundle, PR threads. |
| `hooks/session-start.sh` | Loads the brief and state into a new or cleared session on that branch. |
| `hooks/pre-push.sh` | Blocks `git push` unless HEAD's tree was cleared by the review gate. Blocks force pushes and `gh pr merge`. |
| `hooks/stop.sh` | Blocks the turn from ending while the loop is in an active phase (at most 3 times in a row). |

The hooks do nothing on branches without shepherd state.

## Why it is cheap on tokens

- No orchestrator relays work: the main session implements.
- The reviewer gets a bundle (brief, diff, PR discussion), not the conversation.
- At most 3 reviews per PR. The first runs on Haiku.
- Small deltas such as formatter output, test-only fixes, and clean merges skip re-review.
- CI and hosted review are waited on by background commands, not by polling turns.

## When it interrupts you

- A complex task: plan-only PR first, or implement now.
- A design or API trade-off with no settled answer.
- A claim it cannot reproduce here (credentials, VPN, a cluster).
- A disagreement with the reviewer after the review budget is spent.
- The PR is merge-ready. It never merges.

## Install

```bash
claude plugin marketplace add rohaquinlop/shepherd
claude plugin install shepherd@shepherd
```

Or, inside Claude Code:

```
/plugin marketplace add rohaquinlop/shepherd
/plugin install shepherd@shepherd
```

For local development, add a clone instead: `claude plugin marketplace add ./shepherd`.

Requires `git`, `gh` (authenticated), and `jq`.

## Permissions

The loop runs without you only if routine commands do not prompt. Allow at least:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash */scripts/shepherd.sh *)",
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git add:*)",
      "Bash(git commit:*)", "Bash(git push:*)", "Bash(git fetch:*)", "Bash(git switch:*)",
      "Bash(gh pr view:*)", "Bash(gh pr checks:*)", "Bash(gh pr create:*)", "Bash(gh issue view:*)",
      "Bash(gh run view:*)"
    ]
  }
}
```

Add your repo's check commands (`uv run pytest:*`, `make lint:*`, ...). The pre-push hook still gates every `git push`.

## Per-repo config (optional)

`.claude/shepherd.json`:

```json
{
  "target_branch": "main",
  "verify": ["uv run ruff check", "uv run ty check", "uv run pytest {tests}"],
  "max_reviews": 3,
  "hosted_reviewers": ["coderabbitai"]
}
```

Without it, shepherd uses `origin/HEAD` as the target, the commands documented in the repo's `CLAUDE.md`/`AGENTS.md`, and 3 reviews.

## State

Per branch, in `.claude/shepherd/<branch>/`, excluded from git through `.git/info/exclude`:

- `brief.md`: the task contract
- `plan.md`: the implementation plan
- `decisions.md`: append-only log of decisions, review dispatches, and exemptions
- `state.json`: phase, PR, review budget, cleared tree

## Limits

- The reviewer subagent starts in your working tree, so Claude Code may load that tree's `CLAUDE.md`. The reviewer is told to treat candidate instruction files as review material and to read rules from the clean target-branch checkout, but the harness does not enforce this.
- Invoking `/shepherd:run` authorizes branching, commits, pushes, and PR replies for that change. Your global "never commit unless asked" rule does not stop it.
