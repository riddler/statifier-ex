# Statifier-ex extension: /wurk:commit

Additional required steps, in the order the generic skill's own steps run.
Adds only - see `~/.claude/skills/wurk:commit/SKILL.md` for everything this
does not repeat.

## Step 0: sabotage discipline (the project's answer to `data.sabotage.missing`)

`data.sabotage.missing` is a report, not a gate, per the generic skill - but
this project's policy on that report is a real refusal condition:

- A test with no `# sabotage:` comment directly above it has been *observed*
  passing, not *verified*. That is not a formatting nit to clean up in
  passing.
- **Stop and sabotage it now.** Break the `lib/` code the test covers, confirm
  it goes red for the right reason, revert, confirm green, then write the note
  (`# sabotage: enter_states/2 skips the initial child -> red`) directly above
  the test. Re-run the gate afterward.
- **In auto mode**, sabotaging the test yourself and continuing is fine; what
  is never fine is committing a test with no note. Refuse and report which
  tests are unverified rather than inventing a note for a mutation that was
  never run - a fabricated note is the one failure mode this check cannot
  catch afterward.
- Generated corpus files (`test/scion_tests/`, `test/scxml_tests/`) are exempt
  from this scan and need no notes.
- The mutation protocol itself (what counts as a mutation, the exemption
  grammar, why this is slow on purpose) is defined once, in
  `.claude/wurk/implement.md` - this file states the commit-time refusal
  condition, that file states the protocol. See `docs/testing.md` for the
  rationale behind sabotaging at all.

## Step 1.6: changelog narrowing while v2 is unreleased

On top of the generic needs/no-entry test: while v2 is unreleased, write a
fragment only when **v2 differs from v1**. Re-implementing something v1
already did is invisible to a user calling the public API - most Phase 0 work
needs no fragment at all, and that is the expected outcome, not a step you
skipped.

## Version bump: none

There is no version-bump ritual in this repo. `mix.exs` holds `2.0.0-dev`
until release; there are no alpha/beta/rc versions along the way. Never edit
the version field as part of a commit.

## Gate-guard ledger: ADR-0011

The gate-guard refusal condition the generic skill already states is this
project's ADR-0011: the ledger is `docs/quality-gate-changes.md`, and writing
that entry yourself is granting yourself the permission the check exists to
withhold. Report the finding and stop; do not write the entry regardless of
how routine the guarded change looks.

## Ratchet note

When conformance results move, `mix test.baseline add` (updating
`test/passing_tests.json`) rides in the **same commit** as the feature that
unlocked the newly passing tests - not a follow-up commit. `mix
test.regression` is the gate stage that proves the ratchet holds.

## Diff-classification vocabulary (Step 1)

When classifying the diff for the commit body, use this project's own terms
rather than generic ones: parser elements, interpreter functions, effects, and
ratchet movement (tests newly passing or newly excluded). A commit body
written in this vocabulary is one a reader of this codebase can use without
translation.
