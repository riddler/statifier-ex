# Statifier-ex extension: /wurk:mr

One extra step and two project facts. Adds only - see
`~/.claude/skills/wurk:mr/SKILL.md` for everything this does not repeat.

## Extra step: the ADR judge (unconditional, before step 7's push)

Run the ADR judge regardless of whether step 4's gate applied - a
docs/extension-only diff can carve `gate.rb` out with `applicable: false`, and
this step does not depend on that:

```bash
mix quality --profile merge
```

No kit script wraps this - it makes real `claude` CLI calls, which cost money
and a network round trip, which is why it is disabled in the ordinary gate run
and lives in its own profile instead.

- It **skips cleanly** when there is nothing to check (no `claude` CLI on
  `PATH`, no base ref, or the diff touches none of the judged ADR scopes -
  see `Mix.Statifier.AdrJudge.scope_descriptions/0` for the current list,
  which includes `.claude/wurk/`) - a skip is fine to push through.
- **A finding is a hard refuse.** Treat it exactly as a red gate: report it
  and stop. Do not push past an ADR judge finding in the hope it is a false
  positive.

## Rebase-merge-only

This repo merges by rebase only; `docs/workflow.md:201-223` states the policy
at length. The consequence for this skill: do not offer or perform a squash
merge, and do not restructure the branch's commits on the assumption they will
be squashed. Several separate commits produced by `/wurk:commit --auto` are
fine as they stand and need no cleanup pass before the request opens.

## Changelog question at request time

Same v2/v1 narrowing as `.claude/wurk/commit.md`: while v2 is unreleased, an
entry is warranted only where v2 differs from v1. If step 5 finds one is
needed and the fragment is absent, **ask the user** what it should say - a
changelog entry is a promise to users about observable behavior, and inventing
one describes behavior the code may not actually have.
