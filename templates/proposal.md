# Proposal: <title>

<!-- Written by /shepherd:propose. A fresh session implements from this file with `/shepherd:run <this path>` or `/shepherd:run <this path>#slice-N`.
     Every claim says what it covers and what it did not check. Facts only from evidence; no guessed people, teams, or owners. -->

- **Verdict:** <in progress | feasible | feasible with conditions | not feasible>
- **Started:** <YYYY-MM-DD>
- **Source:** <ticket, message, or "idea in chat">

## Idea

<One or two lines: what the user wants and why, in their terms.>

## Rules that apply

- <rule, and the file it comes from (CLAUDE.md, AGENTS.md, CONTRIBUTING.md, a directory rule)>

## Current state

<How the code works today where the idea lands, with `file:line` for each claim.>

## Impact map

| Code | Relation | Effect of the idea | In scope |
|---|---|---|---|
| <`file:symbol`> | <changed, caller, sibling, duplicate, test, config> | <what must change or stay consistent> | <yes | no, and why> |

## Assumptions

| # | Assumption | Status | Settled by |
|---|---|---|---|
| A1 | <one line the idea relies on> | <untested | confirmed | refuted> | <the check and its result: file, command, probe in scratch> |

## Verdict

<Feasible: why, with the assumptions that prove it.
Feasible with conditions: each condition, who settles it, and how.
Not feasible: the refuted assumption or the rule it breaks, and what would make it feasible.>

## Options

| Option | Summary | Follows the rules | Cost | Risk |
|---|---|---|---|---|
| O1 | <one line> | <yes, or the rule it breaks> | <slices, files> | <one line> |

**Recommendation:** <option, and why. It follows the repo's rules and covers the impact map; it is not picked for the smallest diff.>

## Decisions

| Decision | Why | Settled by |
|---|---|---|
| <what was chosen> | <one line> | <rule, code, evidence, or the user's answer> |

## Slices

<Each slice is one PR. Order by dependency. A slice with no dependency can run in parallel with others.>

### slice-1: <title>

- **Depends on:** <none | slice-N>
- **Scope:** <what changes, and the files>
- **Out of scope:** <what does not>

| # | Acceptance criterion | Test |
|---|---|---|
| 1 | <observable result> | <test that fails today and passes after> |

## Open questions

| Question | Owner | Why it is not settled here |
|---|---|---|
| <question> | <user | team, only if named in evidence> | <what is missing> |

## Next session

<Copy-ready: `/shepherd:run <path to this file>` for all slices in one PR, or `/shepherd:run <path to this file>#slice-1` per slice.>
