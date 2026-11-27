# Plan design review

Part of the run skill (`SKILL.md`, same directory). `$SHEPHERD`, the state dir, and stage numbers mean the same as there.

For a complex task only. It has its own budget (`max_plan_reviews`, default 2) and does not use the
pre-push reviews. Nothing is committed or pushed.

1. `$SHEPHERD policy-base add`.
2. `$SHEPHERD review-start --plan [--escalate "<the finding>"]` → prints `plan call N of M` and
   `model: <model>`. Pass `--escalate` as in the review gate (stage 3, step 6). If it says the
   budget is spent, go to step 6.
3. `$SHEPHERD bundle --plan [--findings <file>]` → prints the bundle path.
4. Dispatch the `shepherd:reviewer` agent with only `BUNDLE: <path>`, `POLICY_BASE: <path>`,
   `plan call N of M`, under the same rules and model choice as the review gate (stage 3, step 5).
   While it runs in the background, `$SHEPHERD set phase=waiting_reviewer`. When its result
   arrives, `$SHEPHERD set phase=study`.
5. Triage every finding as in the review gate: revise `plan.md` for a valid one, dismiss an invalid
   one with evidence, and settle a `DECISION` as in *Decide by default*. If you revised the plan
   and budget is left, go back to step 2, and pass the findings to `bundle --plan --findings`.
6. `$SHEPHERD policy-base remove`. If the last plan call returned `plan current`, or every finding
   left was dismissed with evidence, and every design choice in the plan is settled, record
   `$SHEPHERD decision --title "plan approved" --decision "implement plan.md" --why "<the review
   result and what settled each choice>"` and implement. Otherwise interrupt with one question on
   the unsettled choice: show the plan, the review result, the options, and your recommendation.
   Update `plan.md` with the answer; do not spend another review unless budget is left.
