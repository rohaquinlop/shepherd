# Diagnosis: <title>

<!-- Written by /shepherd:diagnose. A fresh session fixes from this file with `/shepherd:run <this path>`.
     Every claim says what it covers and what it did not check. Facts only from evidence; no guessed people, teams, or owners. -->

- **Status:** <in progress | root cause confirmed | root cause likely | not found>
- **Started:** <YYYY-MM-DD>
- **Source:** <ticket, alert, log, message, or "reported in chat">

## Symptom

<One line: what goes wrong, in the reporter's terms. Then the impact: who or what is affected, since when, how often.>

## Evidence

| # | Evidence | Where it came from | What it shows |
|---|---|---|---|
| E1 | <log line, query result, screenshot, metric> | <file, command, person who ran it> | <one line> |

## Environment checked

- <branch, host, container, config file, env vars, versions: what was confirmed to be the one in use>

## Hypotheses

| # | Hypothesis | Status | Settled by |
|---|---|---|---|
| H1 | <one line> | <untested | confirmed | refuted> | <the check and its result, with evidence #> |

## Root cause

<Confirmed: the cause, the check that proved it, and `file:line` where it lives.
Likely: the best candidate, why, and the one check that would confirm it.
Not found: say so.>

## Reproduction

<Exact steps or the scratch script/test that reproduces it on the current code, and its output. "None yet" if there is none.>

## Ruled out

- <what was ruled out, and the evidence>

## Assumptions to confirm

- <what the conclusion relies on but nobody has checked>

## Open checks

| Check | Owner | Exact command or steps |
|---|---|---|
| <what it would settle> | <Claude | user | team, only if named in evidence> | <copy-ready command, matched to the owner's tools> |

## Fix direction

<The approach in plain words: where the fix belongs and why there. No code. Out of scope: side issues to file separately.>

## Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| 1 | <observable result after the fix> | <test that fails today and passes after> |

## Deadlines

- <data retention, time-travel windows, incident SLAs, or "none">

## Next session

<A copy-ready prompt: `/shepherd:run <path to this file>` plus anything the fixer must know that is not above.>
