# ADR-0011: Quality gate config is not agent-editable

Status: accepted (2026-08-03)

## Context

ADR-0009 picked ex_quality as the quality gate and named the two paths
(`--profile loop`, full `mix quality`) agents run. It settled the tool choice,
not what happens when the gate is red and inconvenient. `CLAUDE.md`'s
ExQuality section already asserts, in prose, that a red gate must never be
turned green by weakening the check: not by lowering a coverage or security
threshold, not by `--skip` flags or `enabled: false` in `.quality.exs` or
`.credo.exs`, not by `@tag :skip` on a failing test, not by narrowing scope.
That rule currently lives only as a reminder an agent has to read and recall
mid-session; nothing records it as a project decision, and nothing catches a
violation if an agent forgets. st-h6p tracks the mechanical half - a check
that catches these edits. This ADR is the policy half: making the rule a
decision the project has made, not a suggestion an agent might weigh against
deadline pressure.

## Decision

`.quality.exs`, `.credo.exs`, and any per-check threshold they configure are
not something an agent - or a human under deadline pressure - may loosen to
make a red gate go green. This applies regardless of the mechanism: lowering
a coverage or security threshold, adding a `--skip` flag, setting
`enabled: false` on a check, tagging a failing test `@tag :skip`, or scoping
a run (`--profile loop`, `--test-scope changed`) and reporting it as if it
were the full gate. A scoped or `--quick` run is never a substitute for a
plain `mix quality` before commit (ADR-0009).

The legitimate escape hatch is a human call, not an agent one: if a check is
genuinely wrong for this project, the agent surfaces the finding and stops,
per `CLAUDE.md`'s existing rule. The user decides whether to change the
config; the agent does not decide on the user's behalf by editing it and
moving on.

This is a specific case of the team-maintainer authority table in
`CLAUDE.md` ("Agent authority in this repo"): `mix quality` may be run any
time, and `git commit` on an issue's worktree branch requires it to be green
first. Editing the gate's own config to manufacture that green is not
authorized by any row in that table - it is not a task-tracking update, not
a commit, not a push. It has no trigger, so it stays unauthorized.

## Consequences

- A red gate is a stop-and-ask condition for config changes, same as any
  other action the authority table doesn't name.
- st-h6p can cite this ADR as the policy a config-tampering check enforces,
  instead of inventing its own rationale.
- Reviewers can point at ADR-0011 instead of re-litigating whether a given
  `.quality.exs` edit was legitimate.
