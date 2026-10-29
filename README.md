# shepherd

A Claude Code plugin that drives one change from an issue to a merge-ready PR, and stops only for decisions that need you.

```
/shepherd:run 123                                     # GitHub issue
/shepherd:run TS-123                                  # Jira story
/shepherd:run https://<site>.atlassian.net/browse/TS-123
/shepherd:run <pasted story or problem statement>
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
- A Jira story it cannot fetch (no Jira MCP or CLI): it asks you to paste it.
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
      "Bash(*/scripts/shepherd.sh *)",
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

A Jira-based work repo:

```json
{
  "target_branch": "develop",
  "branch_pattern": "ts-{number}-{slug}",
  "pr_title": "{KEY}: {summary}",
  "verify": ["uv run ty check", "uv run pytest {tests}", "npx jscpd --min-lines 5 {changed_files}"]
}
```

| Key | Meaning | Default |
|---|---|---|
| `target_branch` | Branch PRs target and reviews read rules from | `origin/HEAD` |
| `verify` | Targeted checks; `{tests}` and `{changed_files}` are filled per change | commands in the repo's `CLAUDE.md`/`AGENTS.md` |
| `max_reviews` | Pre-push review budget per PR | `3` |
| `hosted_reviewers` | Bot or user logins whose PR reviews shepherd waits for | none |
| `branch_pattern` | Branch name; `{type}`, `{ref}`, `{KEY}`, `{number}`, `{slug}`. Also renames a fresh branch a harness created for a new worktree (no commits, no upstream) | `{type}/{ref}-{slug}` |
| `pr_title` | PR title; `{KEY}`, `{summary}` | the repo's convention |

`{ref}` is the issue number or the lowercased Jira key, `{KEY}` the uppercased key, `{number}` the part after the last `-`, `{slug}` a short lowercase form of the summary.

## Jira

shepherd reads a story through a Jira or Atlassian MCP server when one is connected, else through an installed Jira CLI. Without either, it asks you to paste the story. It saves the story to `source.md` in the state dir, and the reviewer gets it in the review bundle. It never comments on or transitions Jira issues.

## State

Per branch, in `.claude/shepherd/<branch>/`, excluded from git through `.git/info/exclude`:

- `brief.md`: the task contract
- `source.md`: the Jira story or pasted text, verbatim
- `plan.md`: the implementation plan
- `decisions.md`: append-only log of decisions, review dispatches, and exemptions
- `last-bundle.md`: the last review bundle, kept when the clean checkout is removed
- `state.json`: phase, PR, review budget, cleared tree

## Limits

- The reviewer subagent starts in your working tree, so Claude Code may load that tree's `CLAUDE.md`. The reviewer is told to treat candidate instruction files as review material and to read rules from the clean target-branch checkout, but the harness does not enforce this.
- Invoking `/shepherd:run` authorizes branching, commits, pushes, and PR replies for that change. Your global "never commit unless asked" rule does not stop it.
