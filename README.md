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

## Diagnose first, fix in a fresh session

When the cause of a bug or incident is not known yet, start with:

```
/shepherd:diagnose <symptom, error, log, or ticket>
```

symptom and evidence → environment check → hypotheses, each settled by the cheapest discriminating check → reproduction → `docs/diagnoses/<date>-<slug>.md`

While a diagnosis is active, a hook blocks edits to anything in the repo except the write-up and a scratch dir for probes, and blocks git commands that commit, switch, reset, or push. The write-up ends with a prompt for the next step:

```
/shepherd:run docs/diagnoses/<date>-<slug>.md
```

The fix runs in a new session, so it starts from the proven facts instead of the diagnosis session's dead ends.

## Lead a whole goal

For a goal bigger than one PR (an idea, an issue, a whole Jira story), start with:

```
/shepherd:lead <goal, issue, Jira key, or docs/proposals/<file>.md>
```

propose (slices with dependencies and files) → `shepherd.sh fleet start` (one `/shepherd:run` session per ready slice, each in its own worktree, stacked on its dependency's branch) → background `fleet wait` → settle each slice's question from evidence, or ask you → start unblocked slices → report the merge queue

The lead never implements or merges. Slice sessions run in the background with your permission mode, so they need the allowlist below, or they stall on a prompt; `shepherd.sh fleet status` shows a stalled slice, and `claude attach <id>` opens it. The lead's Stop hook and resume note follow the session that last set its phase; after `/clear` or a restart, run `/shepherd:lead <proposal>` again to resume.

## Propose before you build

When you have an idea and do not know yet if it is possible, start with:

```
/shepherd:propose <idea, issue, Jira key, or pasted text>
```

repo rules → current state → impact map (callers, siblings, duplicates) → assumptions, each settled by the cheapest read-only check → verdict → options with a rule-compliant recommendation → slices → `docs/proposals/<date>-<slug>.md`

The same guard as a diagnosis keeps the session read-only. Each slice is one PR with its dependencies and acceptance criteria. Implement in a new session:

```
/shepherd:run docs/proposals/<date>-<slug>.md            # every slice
/shepherd:run docs/proposals/<date>-<slug>.md#slice-1    # one slice
```

## What runs where

| Part | Role |
|---|---|
| `skills/run` | The playbook. Claude follows it in your main session and writes the code there. |
| `skills/diagnose` | Finds and proves a root cause, writes it to `docs/diagnoses/`. Never fixes. |
| `skills/propose` | Checks whether an idea is possible, writes a verdict, options, and slices to `docs/proposals/`. Never implements. |
| `skills/lead` | Coordinates a goal: proposes slices, runs them in parallel through the fleet commands, settles their questions, reports the merge queue. Never implements or merges. |
| `lib/fleet.sh` | `shepherd.sh fleet`: starts a background session per ready slice in its own worktree, tracks status from `claude agents`, shepherd state, and `gh`, and wakes the lead on changes. No model calls. |
| `skills/followup` | Parks a verified, out-of-scope side issue as a GitHub issue or Jira draft, after your yes. Never widens the current change. |
| `hooks/diagnose-guard.sh` | While a diagnosis or a proposal is active, blocks edits outside the write-up and scratch dir, and git commands that change state. |
| `agents/reviewer` | A fresh reviewer with only `Read`, `Grep`, and `Glob`. It reads a review bundle and the target branch's rules, then returns findings or `current at <sha>`. |
| `scripts/shepherd.sh` | State, decision log, review budget, review bundle, PR threads. |
| `hooks/session-start.sh` | Loads the brief and state into a new or cleared session on that branch, and tells a resumed lead session its fleet. |
| `hooks/pre-push.sh` | Blocks `git push` unless HEAD's tree was cleared by the review gate. Blocks force pushes, `gh pr merge`, and `gh api` merge writes. Blocks `git push --no-verify` and `git -c core.hooksPath=…`, which skip the git gate. Reads each command in a call (lines, `;`, `&&`, pipes, `$()`, backticks, `bash -c`, `env`). Without `jq` it blocks any call that names a push or a merge. |
| `hooks/git-pre-push.sh` | The git gate. `shepherd init` sets the worktree's `core.hooksPath` (per worktree, through `extensions.worktreeConfig`) to `shepherd/_githooks/` in its git dir. Its `pre-push` rejects a push of a branch with state unless the pushed tree is the cleared tree and the push fast-forwards, whatever command ran it. Every other hook there runs the repo's own hook of that name (`hooks/git-chain.sh`). |
| `hooks/stop.sh` | Blocks the turn from ending while the loop or the lead is in an active phase (at most 3 times in a row). |

The hooks do nothing on branches without shepherd state (except the Stop and SessionStart hooks for an active lead, read from the fleet record), and the diagnose guard does nothing without an active diagnosis or proposal.

## Why it is cheap on tokens

- No orchestrator relays work: the main session implements.
- The reviewer gets a bundle (brief, diff or plan, PR discussion), not the conversation.
- At most 3 pre-push reviews per round, plus one verify call that checks fixes to the last round's findings, and at most 2 plan design reviews for a complex task. The first runs on Haiku, and so does every call once the PR exists, every call in a later round, and every verify call.
- A new round starts with each comment or CI fix round on the PR, or when you ask shepherd to re-run reviews (`shepherd.sh review-round --user --reason "..."`).
- Small deltas such as formatter output, test-only fixes, and clean merges skip re-review.
- CI and hosted review are waited on by background commands, not by polling turns.

## When it interrupts you

shepherd decides by default. A choice is settled when the repo's rules, the source, the brief and decision log, an existing pattern in the code, or something the user said or a check in the session that directly answers the choice settles it. It records the choice and what settled it in `decisions.md`, and keeps going. Its own choices and recommendations must follow the repo's rules and cover the impact check (callers, siblings, duplicates, helpers); it never picks an option only because the diff is smaller.

It stops only for:

- A design, API, or behavioral choice that nothing above settles, including one in a complex task's plan. A complex task whose plan review is clean and whose choices are all settled goes straight to implementation. The plan stays out of git.
- A Jira story it cannot fetch (no Jira MCP or CLI): it asks you to paste it.
- A claim it cannot reproduce here (credentials, VPN, a cluster).
- Findings left after the verify call on the last round's fixes: start a new round, or accept the tree as is.
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
| `max_reviews` | Pre-push review budget per round | `3` |
| `max_plan_reviews` | Plan design reviews for a complex task, separate from `max_reviews` | `2` |
| `hosted_reviewers` | Bot or user logins whose PR reviews shepherd waits for | none |
| `branch_pattern` | Branch name; `{type}`, `{ref}`, `{KEY}`, `{number}`, `{slug}`. Also renames a fresh branch a harness created for a new worktree (no commits, no upstream) | `{type}/{ref}-{slug}` |
| `pr_title` | PR title; `{KEY}`, `{summary}` | the repo's convention |

`{ref}` is the issue number or the lowercased Jira key, `{KEY}` the uppercased key, `{number}` the part after the last `-`, `{slug}` a short lowercase form of the summary.

## Jira

shepherd reads a story through a Jira or Atlassian MCP server when one is connected, else through an installed Jira CLI. Without either, it asks you to paste the story. It saves the story to `source.md` in the state dir, and the reviewer gets it in the review bundle. It never comments on or transitions Jira issues.

## State

Per branch, in `shepherd/<branch>/` under the worktree's git dir (`git rev-parse --git-dir`: `.git/` in the main worktree, `.git/worktrees/<name>/` in a linked one). It is outside the work tree, so git never sees it and Claude Code's Bash edit diff does not list it (checked in Claude Code 2.1.328). Each worktree has its own, so parallel sessions in different worktrees never share state:

- `brief.md`: the task contract
- `source.md`: the Jira story or pasted text, verbatim
- `plan.md`: the implementation plan, never committed
- `decisions.md`: append-only log of decisions, review dispatches, and exemptions
- `last-bundle.md`: the last review bundle, kept when the clean checkout is removed
- `state.json`: phase, PR, review budget, cleared tree

Per worktree, in `shepherd/_githooks/` under the same git dir: the git gate's hook stubs. When `extensions.worktreeConfig` is unset, `init` sets it to `true` in the shared config, so per-worktree config applies to the whole repo. Running `shepherd init` again reinstalls them, for example after a plugin update moves the plugin path. To remove the gate: `git config --worktree --unset core.hooksPath`. It is not installed when the shared config sets `core.worktree` or `core.bare=true`, sets `extensions.worktreeConfig=false`, or the worktree sets its own `core.hooksPath`; `init` prints a warning and the PreToolUse hook still gates pushes.

Per worktree, for an active diagnosis or proposal (one at a time), in `shepherd/_diagnose/` under the same git dir: `active.json` (turns the guard on; `kind` says which) and `scratch/<slug>/` for probes. The write-up itself is in `docs/diagnoses/` or `docs/proposals/`, which are not excluded from git: commit it only if you want it in the repo.

For a fleet, in `shepherd/_fleet/` under the common git dir (shared by all worktrees): `<slug>.json` (each slice's dependencies, files, base, branch, worktree, session, and the lead's phase) and `worktrees/<slug>-slice-N/`.

Older versions kept this in `.claude/shepherd/` in the work tree. The first shepherd command or hook in that worktree moves it to the git dir.

## Limits

- `git push --no-verify` skips the git gate. The PreToolUse hook denies it in Claude Code; a `--no-verify` push from your own terminal is not checked.
- The diagnose guard sees file edits and git commands, not shell redirects or `sed -i`. The skill forbids those, but the hook cannot block them.
- The reviewer subagent starts in your working tree, so Claude Code may load that tree's `CLAUDE.md`. The reviewer is told to treat candidate instruction files as review material and to read rules from the clean target-branch checkout, but the harness does not enforce this.
- Invoking `/shepherd:run` authorizes branching, commits, pushes, and PR replies for that change. Your global "never commit unless asked" rule does not stop it.
