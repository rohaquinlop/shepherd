# Exempt deltas

Part of the run skill (`SKILL.md`, same directory). `$SHEPHERD`, the state dir, and stage numbers mean the same as there.

Classify the actual delta from the last **reviewed** commit, not the last pushed one:

| Class | Delta | Check before claiming it |
|---|---|---|
| `format` | output of the repo's formatter or lint autofix | rerunning the tool on the reviewed commit gives the same tree |
| `tests` | test code or fixtures only, matching established behavior | full diff is tests only; affected tests pass; no snapshot blesses a new regression |
| `comments` | comments or docstrings only | no non-comment line in `git diff <reviewed>..HEAD` |
| `merge` | target-branch merge with no conflict resolution | branch diff against the old base equals the diff against the new base |
| `reviewed-tree` | return to a tree already reviewed | `git rev-parse HEAD^{tree}` equals a recorded reviewed tree |
| `lockfile` | lockfile-only dependency bump | only lock and manifest paths changed |

Then `$SHEPHERD clear --exempt <class> --reason "<the check and its result>"`. Anything else, at
any size, re-reviews. A cassette or snapshot change that changes a request body, a conflict
resolution, and any public API change are never exempt.
