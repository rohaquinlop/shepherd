# Wait for hosted review

Part of the run skill (`SKILL.md`, same directory). `$SHEPHERD`, the state dir, and stage numbers mean the same as there.

If `.claude/shepherd.json` lists `hosted_reviewers`, or the repo runs a review bot:

- In the Claude desktop app, prefer the PR's Auto-fix: the app wakes the session on new comments
  and CI failures.
- Otherwise `$SHEPHERD set phase=waiting_review` and run `$SHEPHERD wait-review --timeout 1800` as a
  background command. New activity → stage 6. Timeout → stage 8, and say the review has not landed.
