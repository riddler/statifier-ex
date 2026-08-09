# Statifier-ex extension: /wurk:implement

This file is passed **by path** to `--loop` phase subagents that have no
other context, so it is written to need no external read to follow. See
`~/.claude/skills/wurk:implement/SKILL.md` for everything this does not
repeat.

## The sabotage protocol (full statement)

Sabotage every new or changed test that asserts `lib/` behavior. A test that
passed on its first run has not been verified, only observed.

For each such test:

1. Break the `lib/` code it covers with a single plausible mutation: invert a
   condition, drop a clause, skip a recursive call, or return the input
   unchanged.
2. Run the test and confirm it fails **for the right reason** - the failure
   message should point at the exact behavior the mutation broke, not at some
   unrelated crash.
3. Revert the mutation.
4. Confirm the test is green again.
5. Record it in one line directly above the test:

   ```elixir
   # sabotage: enter_states/2 skips the initial child -> red
   test "compound state enters its initial descendant" do
   ```

Rules that matter here:

- **A test that stays green under sabotage is broken.** Fix the test - never
  weaken the mutation until it reddens. A mutation chosen so gently that
  nothing notices is not evidence the test works.
- **Deleting a function body or raising unconditionally is not a mutation.**
  Everything fails when you do that, so nothing is learned about what the test
  actually checks.
- **Generated corpus files are exempt**: anything under `test/scion_tests/` or
  `test/scxml_tests/` needs no sabotage note.
- **Harness plumbing that asserts no `lib/` behavior is exempt too, but says
  so explicitly** - never omit the line silently:

  ```elixir
  # sabotage: n/a - this test only checks fixture loading, not lib/ behavior
  ```

- **This is slow on purpose.** Budget for it in the phase itself rather than
  deferring it to "later" - there is no later. `/wurk:commit` (via
  `.claude/wurk/commit.md`) refuses to commit a new test with no sabotage note
  and will not invent one for you.

See `docs/testing.md` for the full rationale behind this discipline.

## Interpreter domain rules

If the phase touches the Appendix D interpreter functions in
`lib/statifier/`:

- **Keep the spec's function names and pseudocode structure** (ADR-0002):
  `select_transitions`, `compute_exit_set`, `compute_entry_set`, `microstep`,
  `enter_states`, `exit_states`, and so on, in snake_case, mirroring the
  pseudocode's control flow rather than an Elixir-idiomatic rewrite. A
  deviation from the pseudocode needs an inline comment citing the mechanical
  reason it was necessary - an unexplained deviation is a semantic bug, not a
  style choice.
- **Return effects, never perform side effects in the core** (ADR-0003): the
  interpreter's pure core returns `{state, [effect]}`; it does not call out to
  I/O, processes, or anything with an observable side effect itself.
- **Evaluations return `{:ok, v} | {:error, e}`.** Only the interpreter maps a
  `{:error, e}` to an `error.execution` event. Never rescue-to-default at a
  leaf function - swallowing an error there hides it from the event mechanism
  the whole architecture is built around.
- If the change makes conformance tests newly pass, ratchet them
  (`mix test.baseline add`) in the same change that unlocked them.

## The debugging move

When something isn't working as expected and the behavior is in the
interpreter: **diff the function against the Appendix D pseudocode before
anything else.** That single comparison is the fastest way to find where this
codebase's behavior and the spec's algorithm diverged, and it is the first
thing to try in this project - before adding logging, before searching test
history, before guessing.

## Test conventions

A fresh phase subagent will not have read `CLAUDE.md`, so these are restated
here:

- Structs and `MapSet`s for data, not bare maps/lists where a structured type
  fits.
- `@spec` on public functions.
- Pattern matching over multiple `assert` calls in tests, where a single
  pattern match can express the same check.
- XML fixtures in tests are triple-quoted heredocs at 4-space base
  indentation.
- Scratch directories in tests use `@tag :isolated_tmp_dir`
  (`Statifier.TmpDir`) - **never** ExUnit's own `@tag :tmp_dir`.
