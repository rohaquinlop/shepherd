---
name: followup
description: Park a real bug or improvement found while working on something else — out of scope for the current change, but worth doing — as a GitHub issue or a Jira story draft, with enough context that a fresh session can pick it up cold. Does not touch the current change. Use when shepherd:run, shepherd:diagnose, or a review turns up a side issue. Not for trivial in-scope fixes (just do them) or for hunches (verify them first).
argument-hint: "<the side issue, in a sentence>"
---

# shepherd: follow-up

You found work that is real and worth doing, but it does not belong in the current change. Write it up so a future session can start from it, then go back to the current work without widening it.

Adapted from the `file-followup-issue` skill in [pydantic-ai](https://github.com/pydantic/pydantic-ai).

## Gate: all three must hold

1. **The current change does not need it.** It closes its own issue or story without this.
2. **It is real and verified.** You reproduced the bug or confirmed the gap with evidence: a failing command, a query result, a `file:line`. A hunch that "others might also be affected" is not a follow-up; verify it first, or mention it in one line as unverified and stop.
3. **It is non-trivial and out of scope.** Fixing it here would add its own design decisions, carry open questions, or reach code the current change does not touch.

If a gate fails, do the alternative and stop:

- Trivial and in scope: fix it in the current change.
- In scope but larger: add it to the current plan.
- Not a real problem: drop it.

## Steps

1. **Find the tracker.** Use the one the current work comes from: a GitHub issue → GitHub; a Jira story → Jira. If there is no current work, use GitHub when the repo has a GitHub remote, else ask.
2. **Dedup.**
   - GitHub: `gh issue list --state all --search "<3-5 distinctive keywords>" --limit 20`.
   - Jira: search with a Jira or Atlassian MCP tool when one is connected.

   If a clear match exists, link it instead of filing a new one, and skip to step 5.
3. **Draft** the title and body with the template below. Write each to a file with your editor tool, never into a shell argument: quoted code and reviewer text can contain `$(...)` and backticks that the shell would run.
4. **Confirm, then create.** Filing is outward-facing. Show the user the title and body and wait for a yes.
   - GitHub: `title=$(cat <title file>)` then `gh issue create --title "$title" --body-file <body file>`. Add labels only if `gh label list` shows they exist.
   - Jira: create it through the connector only on that yes. If no connector works, give the user the draft to paste.
5. **Log the deferral** so reviewers of the current change see why it was parked:
   - shepherd:run active on this branch: `$SHEPHERD decision --title "defer: <short title>" --decision "Filed as <link> instead of fixing here" --why "Out of scope: <decisions | open questions | reach>" --source <link>`.
   - shepherd:diagnose active: add it under **Fix direction → out of scope** in the write-up, with the link.
6. **Report** the link in one line. Do not expand the current change.

## Issue body template

```markdown
## Background
<what we were doing and where this surfaced; link the originating PR, story, or diagnosis>

## The problem
<the bug or improvement, concrete and specific>

## Evidence
<how it was verified: the command and its output, the query result, or the failing test>

## Why it's out of scope for the originating change
<the specific reason: its own design decisions, open questions, or reach>

## Where
- `path/to/file.py` — `Class.method`   <!-- file and symbol, no line numbers: they drift -->

## Suggested direction (low confidence)
<optional starting point, marked as a lead, not a decision. Omit if you have none.>
```
