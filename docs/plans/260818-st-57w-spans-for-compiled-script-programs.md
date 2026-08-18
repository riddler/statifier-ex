# Spans for Compiled Script Programs Implementation Plan

## Overview

Move `Statifier.Compiler.Expressions.compile_program/3` from
`Predicator.compile_program_with_positions/1` to
`Predicator.compile_program_with_spans/1`, rewrite the docs that record the
positions choice as a live stopgap into a record of a resolved one, and pin
the user-visible payoff ADR-0014 item 4 bounds with a test: a `<script>`
statement that fails at run time now puts a real `:span` in `error.execution`'s
`data:` payload instead of `nil`.

Bead: `st-57w` (mirrors `px-iov`, which is closed - see Current State).

## Current State Analysis

`compile_program/3` (`lib/statifier/compiler/expressions.ex:185-193`) calls
`Predicator.compile_program_with_positions/1` and stores the returned
`%Predicator.Compiled{}` whole. Its sibling `compile/3`
(`lib/statifier/compiler/expressions.ex:84-94`) already calls
`Predicator.compile_with_spans/1`. The asymmetry exists only because, when
`st-af3.17` wired `<script>` bodies, predicator exposed no spans-based compile
for statement programs.

**That constraint is gone.** The bead's own 2026-08-18 mirror-refresh note
records `px-iov` closed (PR #157) and `px-ehn` closed (PR #158); this repo
pins `predicator ~> 9.0` (`mix.exs`), and
`deps/predicator/lib/predicator.ex:856-895` defines
`compile_program_with_spans/1`, documented as: "`compiled.positions` maps each
instruction's 0-based index to the `t:Predicator.Types.span/0` of the AST node
that emitted it ... The instruction that terminates a statement - `store` for
an assignment, `pop` for a bare expression statement - carries that
statement's own source extent."

**Two items in the bead's WHAT are already done and are not planned work here:**

1. The WHAT asks to replace `program_parse_error/3`'s re-parse of a formatted
   failure string. There is no `program_parse_error/3` in the module any more:
   `compile_program/3`'s failure arm already pattern-matches
   `{:error, %ParseError{} = parse_error}` and hands the struct straight to
   `Error.expression_compile_error/4`
   (`lib/statifier/compiler/expressions.ex:189-190`). `st-59d` (the 8.0 bump,
   merged via PR #142) deleted the re-parse and the comment explaining it, as
   its own acceptance criteria required. The bead's note says the same; this
   plan records it so nobody re-plans it.
2. The doc paragraph the WHAT locates at `expressions.ex:163-165` has since
   moved: the live text is `compile_program/3`'s `@doc`
   (`lib/statifier/compiler/expressions.ex:159-182`), and the module
   `@moduledoc` (`:1-15`) carries a second, narrower statement of the same
   choice at `:10-14`. Both are in scope for the rewrite; the line numbers in
   the bead are not.

Item 4 of the bead (the `error.execution` payload question) is **unresolved
until this plan's Phase 2**, and this plan resolves it rather than deferring
it. Measured on the current pin (probe run against
`deps/predicator` under this worktree, program `"x = 1;\ny = zzz + 1;\n"`
executed with `on_unbound: :error`):

| compile entry point | error struct | `:position` | `:span` |
|---|---|---|---|
| `compile_program_with_positions/1` | `UndefinedVariableError` | `{2, 5}` | `nil` |
| `compile_program_with_spans/1` | `UndefinedVariableError` | `{2, 5}` | `{{2, 5}, {2, 8}}` |

`Statifier.Evaluator.run_program/2`
(`lib/statifier/evaluator.ex:417-465`) wraps that struct with
`Statifier.Evaluator.Error.new(source, error)`, which lifts `:span` to the top
level (`lib/statifier/evaluator/error.ex:44`).
`Statifier.Machine.Content.Script`'s `execute/2`
(`lib/statifier/machine/content/script.ex:88-95`) returns it as the block
runner's failure reason, and
`Statifier.Interpreter.Content.raise_execution_error/4`
(`lib/statifier/interpreter/content.ex:266-270`) puts it in `data:` on the
`error.execution` platform event. So the whole payoff chain already exists;
the swap in Phase 1 is the only thing standing between it and a non-nil span.

## Desired End State

- `compile_program/3` compiles with `compile_program_with_spans/1`, and the
  `%Predicator.Compiled{}` it stores in `Machine.program()` carries a span
  table.
- The moduledoc and `compile_program/3`'s `@doc` describe the positions choice
  as a resolved stopgap - what it was, why it existed, and what closed it -
  rather than as current behavior.
- `error.execution`'s `data:` for a failed `<script>` statement carries a
  `Statifier.Evaluator.Error` whose `:span` is the failing subexpression's
  extent, asserted by a test, not by reasoning.
- `mix quality --profile merge` is clean on the `adr-0014-expression-spans`
  finding (`lib/mix/statifier/adr_judge.ex:184-186`), and full `mix quality`
  is green.

Verification: the ADR judge stage under `--profile merge` reports no finding
keyed `adr-0014-expression-spans`, and `grep -rn compile_program_with_positions
lib/` returns nothing outside historical `docs/plans/` and `docs/research/`
prose.

### Key Discoveries:

- `lib/statifier/compiler/expressions.ex:185-193` - the single call site; the
  swap is one identifier.
- `deps/predicator/lib/predicator.ex:856-895` - `compile_program_with_spans/1`;
  same `{:ok, %Compiled{}} | {:error, %ParseError{}}` contract as the positions
  variant, so no call-site shape changes.
- `deps/predicator/lib/predicator.ex:899-915` - `build_compiled_result/1` is
  shared by all four `_with_` entry points, which is why the existing
  "a parse failure carries a `:span` in every mode" claim in the current
  `@doc` stays true after the swap and must be kept, not deleted.
- ADR-0014 item 1: "Cond wiring targets predicator 4.0's
  `compile_with_spans/1` ... If cond wiring must begin before 4.0 ships, it
  threads the identical seam with `compile_with_positions/1` / `:positions` as
  a stopgap, storing the table in the same field, so the st-2pj bump widens it
  mechanically - the seam is the commitment, the width follows the pin."
  This plan is that mechanical widening, applied to the program path.
- ADR-0014 Consequences: cond wiring "accepts the point-position stopgap in
  item 1 with a known mechanical widening" - so removing the stopgap needs no
  ADR amendment, only its record updated.
- ADR-0014 item 4 commits to four payload fields: "the constraint-3 identity of
  the owning node ..., the expression source string, the predicator error
  struct, and its `:span` (nil when predicator cannot attribute one). Exact
  payload shape is settled at implementation; the fields are the commitment."
  All four already reach `error.execution`; only the fourth is currently nil
  for programs.
- ADR-0014's 2026-08-18 amendment (st-i9d) makes a `protected_roots:` refusal a
  policy check outside item 4. `run_program/2`'s
  `{:error, machine_state, {:system_variable, root}, post_context}` arm
  (`lib/statifier/evaluator.ex:435-437` - predicator's own `protected_root`
  refusal - and `:457-459` - the post-hoc system-changed check) therefore
  stays span-free by design. Phase 2 must not "improve" it.
- `lib/statifier/evaluator/error.ex:14-18` carries a stale reason: it justifies
  `Map.get/2` by "`Predicator.Errors.ParseError` has no `:span` field", but
  since predicator 8.0 `ParseError` does
  (`deps/predicator/lib/predicator/errors/parse_error.ex:36`). The struct that
  actually lacks `:span` today is `Predicator.Errors.LocationError`
  (`deps/predicator/lib/predicator/errors/location_error.ex:64`). The
  defensive call stays; its stated reason is wrong and is corrected in Phase 2.
- Four test files build a program by hand:
  `test/statifier/evaluator_test.exs:57-60`,
  `test/statifier/interpreter/content_test.exs:471`,
  `test/statifier/machine/content/script_test.exs:33-36` (setup helpers), and
  `test/statifier/compiler/expressions_test.exs:127` (a sabotage line naming
  the positions function, which stays as-is - it describes a mutation, not
  production behavior).

## What We're NOT Doing

- **Not** giving `error.execution` a separate "statement extent" field
  alongside the failing subexpression's span. The span table does hold it (the
  terminating `store`/`pop` instruction carries the statement's extent - probe:
  index 7 of `"x = 1;\ny = zzz + 1;\n"` is `{{2, 1}, {2, 12}}`), but predicator
  reports the *failing instruction's* span, and ADR-0014 item 4's committed
  field list is "the predicator error struct, and its `:span`" - the struct's
  own span, not a host-computed widening of it. Item 4's Consequences example
  ("columns 22-27 of `user.age > 18 AND score > 5`") is subexpression
  granularity, which is exactly what the swap delivers. Adding a fifth payload
  field would widen a payload ADR-0014 bounds, so it is a direction decision
  (an ADR-0014 amendment) rather than a chore, and no follow-up bead is filed
  for it here: nothing in the record asks for it, and filing a bead for an
  un-argued want is how a tracker fills with ADR-shaped speculation. If a
  consumer later needs it, the amendment comes first.
- **Not** touching `write_location/4`'s two policy tuples or `run_program/2`'s
  `{:system_variable, root}` arm. ADR-0014's 2026-08-15 and 2026-08-18
  amendments put all three outside item 4 explicitly: "no failing
  subexpression exists to underline, the root is the whole diagnostic".
- **Not** amending ADR-0014. The Consequences section already contemplates this
  widening; the ADR is correct as written and only the code's record of the
  stopgap is stale.
- **Not** changing `compile/3`, `static/1`, or `inline_value/1` - the two that
  compile anything are already on `Predicator.compile_with_spans/1`, and
  `static/1` compiles nothing.
- **Not** writing a `changelog.d/st-57w.md` fragment.
  `changelog.d/README.md`'s v2 rule is "write a fragment when v2 differs from
  v1", and this improves an internal diagnostic payload inside a rewrite whose
  `<script>` support is itself unreleased. Nobody upgrading from 1.x can tell
  the difference.
- **Not** re-running the corpus or touching `test/passing_tests.json`. No
  conformance test can change: a span in an error payload does not change
  whether a document's configuration matches, and no corpus assertion reads
  `error.execution`'s `data:`. `mix test.regression` still runs as a phase
  criterion to prove the ratchet did not move.

## Implementation Approach

Two phases, split at the seam between "what is compiled" and "what a failure
reports", which is also the boundary between the compiler and the
evaluator/interpreter module families.

Phase 1 is the swap plus every doc and test that describes *the compile*. It
is self-contained: the call-site contract is identical in both directions, so
the suite must stay green with no behavior change other than the table's
width.

Phase 2 is the bead's item 4: prove, by test, that the widened table reaches
`error.execution`, and correct the one stale sentence in
`Statifier.Evaluator.Error`'s moduledoc that the investigation turned up.
Phase 2 depends on Phase 1's swap for its assertion to hold, but Phase 1 is
green and committable without it - a spans compile is not wrong just because
nothing yet asserts the payoff downstream.

Neither phase touches the interpreter's Appendix D functions, so the
Appendix D rule (`.claude/wurk/plan.md`, ADR-0002) has no deviation to
declare: the pseudocode says nothing about expression compilation, and
`raise_execution_error/4`'s errors-are-events conversion is untouched.

## Phase 1: Compile script programs with spans

### Overview

Swap the compile entry point, rewrite the two doc sites that record the
positions choice, and move the three test helpers that build a program by
hand onto the same entry point production uses.

### Changes Required:

#### 1. The call site

**File**: `lib/statifier/compiler/expressions.ex`
**Changes**: `compile_program/3`'s `case` subject moves to the spans variant.

```elixir
    case Predicator.compile_program_with_spans(source) do
      {:ok, %Predicator.Compiled{} = compiled} ->
        {:ok, {:program, compiled, source}}

      {:error, %ParseError{} = parse_error} ->
        {:error, Error.expression_compile_error(owner, source, parse_error, location)}
    end
```

#### 2. `compile_program/3`'s `@doc`

**File**: `lib/statifier/compiler/expressions.ex:159-182`
**Changes**: the success paragraph names `compile_program_with_spans/1` and
says what the table now holds, citing the upstream doc's own words about the
statement-terminating instruction. The failure paragraph keeps its
"a span is present in every compile mode, because it comes from the token
stream" claim - it is still true and still worth stating, since it is the
reason the failure arm needed no change - but drops the trailing clause
"even though this function compiles with positions rather than spans", which
is now false. The paragraph records that the positions call was a stopgap
ADR-0014 item 1 sanctioned, and that predicator `~> 9.0` closed it. Cite
ADR-0014 item 1's own sentence ("the seam is the commitment, the width follows
the pin") rather than paraphrasing it.

#### 3. The `@moduledoc`

**File**: `lib/statifier/compiler/expressions.ex:10-14`
**Changes**: the current text says "`compile/3` always calls
`Predicator.compile_with_spans/1`, never `compile_with_positions/1`" - true but
now half the story. It becomes a statement about the module: every compile
entry point in it is a spans variant, `compile_program/3` included, and the
program path's point-position stopgap is closed. Keep the item 2 sentence
about `%Predicator.Compiled{}` threading its own table, which is unchanged.

#### 4. Test helpers

**Files**: `test/statifier/evaluator_test.exs:57-60`,
`test/statifier/interpreter/content_test.exs:471`,
`test/statifier/machine/content/script_test.exs:33-36`
**Changes**: each `program/1` / `script_node/2` helper calls
`Predicator.compile_program_with_spans/1`. These are fixtures standing in for
`Compiler.Expressions.compile_program/3`'s output; leaving them on the
positions variant would mean every downstream test exercises a table shape
production no longer produces. No sabotage lines are added or changed for
these edits: they are harness fixtures, not new assertions about `lib/`
behavior, and the tests they feed keep their existing sabotage lines.

`test/statifier/compiler/expressions_test.exs:127`'s sabotage comment mentions
`compile_program_with_positions/1` as the mutation to apply to `compile/3`.
It stays verbatim - the function still exists upstream and the mutation still
reddens the test.

#### 5. A test that the stored table is a span table

**File**: `test/statifier/compiler/expressions_test.exs`
**Changes**: extend the existing
`"compile_program/3 compiles a valid statement program"` test (`:76-84`), or
add one beside it, asserting the stored `compiled.positions` values are spans
(`{{line, col}, {line, col}}` pairs) and not point positions
(`{line, col}`). The two shapes are distinguishable by structure alone: a
point is a 2-tuple of integers, a span a 2-tuple of 2-tuples.

```elixir
  # sabotage: swap compile_program_with_spans/1 back to
  # compile_program_with_positions/1 in compile_program/3 -> every table entry
  # becomes a point {line, column} instead of a {start, stop} span pair, and
  # this test goes red
  test "compile_program/3 stores a span table, not a point-position table" do
    assert {:ok, {:program, %Predicator.Compiled{} = compiled, _source}} =
             Expressions.compile_program("x = 1;\ny = x + 1;", {:content, 0}, loc(0))

    assert map_size(compiled.positions) > 0

    Enum.each(compiled.positions, fn {index, span} ->
      assert {{start_line, start_column}, {end_line, end_column}} = span,
             "instruction #{index} carries #{inspect(span)}, not a span"

      assert is_integer(start_line) and is_integer(start_column)
      assert is_integer(end_line) and is_integer(end_column)
    end)
  end
```

Run the sabotage for real (edit the call site back to the positions variant,
watch it go red, revert) before committing - the comment is a claim about an
observed run, per `docs/testing.md`.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` used between edits (never as the phase gate)
- [x] Full `mix quality` green
- [x] `mix test.regression` passes with the ratchet unchanged
- [x] `grep -rn "compile_program_with_positions" lib/ test/` returns only
      `test/statifier/compiler/expressions_test.exs`'s sabotage comment
- [x] The new span-table test passes, and reddens under its stated sabotage
      when the swap is reverted

#### Manual Verification:

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - vacuously here, since neither `compile_program/3` nor any
      interpreter function it feeds changes shape, but confirm no Appendix D
      procedure was touched
- [ ] The rewritten moduledoc and `@doc` read as a record of a *resolved*
      stopgap, name what closed it (predicator `~> 9.0` /
      `compile_program_with_spans/1`), and quote ADR-0014 item 1 accurately
      against `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
- [ ] No regressions in `<script>` execution: `mix test
      test/statifier/machine/content/script_test.exs
      test/statifier/interpreter/content_test.exs` green

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Pin ADR-0014 item 4's payoff for script failures

### Overview

Assert that a `<script>` statement failing at run time puts a real span in
`error.execution`'s `data:`, and correct `Statifier.Evaluator.Error`'s stale
justification for `Map.get/2`.

This is the bead's item 4, decided rather than deferred: **the payoff is in
scope for this bead and needs no production change beyond Phase 1's swap.**
The argument is the chain in Current State - `run_program/2` already wraps
predicator's struct with `Evaluator.Error.new/2`, which already lifts `:span`,
and `raise_execution_error/4` already puts that struct in `data:`. Before
Phase 1 the span was nil because the table was point positions; after it, it
is the failing subexpression's extent. What the bead asks ("check whether
`error.execution`'s `data:` payload can now name the statement's own extent")
therefore resolves to: yes at subexpression granularity, which is the
granularity ADR-0014 item 4 commits to, and the only work owed is a test that
holds it there.

### Changes Required:

#### 1. An end-to-end span assertion through the block runner

**File**: `test/statifier/interpreter/content_test.exs`, in the
`"<script>, through the real block runner"` describe block
**Changes**: add a test that runs a script whose *second* statement fails, and
asserts the raised `error.execution`'s `data` is a
`%Statifier.Evaluator.Error{}` whose `span` is a non-nil `{start, stop}` pair
located on line 2 - i.e. it names the failing statement's subexpression, not
the whole program and not `nil`.

Use an unbound load for the failure: `run_program/2` builds its context
through `Evaluator.context/1`, and the datamodel is the only thing the test
must arrange. A source of `"x = 1;\ny = zzz + 1;"` with `"x"` and `"y"`
declared and `zzz` absent fails with `%UndefinedVariableError{}` carrying
`span: {{2, 5}, {2, 8}}` (measured on this pin; assert the shape and the line
number, not the exact columns, so a predicator column-accounting change is
not a false red here).

```elixir
  # sabotage: revert compile_program/3 to
  # Predicator.compile_program_with_positions/1 -> the UndefinedVariableError
  # carries :position but no :span, Evaluator.Error lifts nil, and the span
  # assertion below goes red
  test "a failed <script> statement's error.execution data carries the failing subexpression's span" do
```

The assertion targets `error_event.data.span` and `error_event.data.source`,
and keeps `error_event.cause.origin == {:content, _, @owner}` in the same
test - together they are ADR-0014 item 4's four committed fields (owner
identity from the origin stamp, source string, error struct, span) observed on
one event.

#### 2. Correct `Statifier.Evaluator.Error`'s moduledoc

**File**: `lib/statifier/evaluator/error.ex:14-18`
**Changes**: the parenthetical "`Predicator.Errors.ParseError` has no `:span`
field, hence `Map.get/2` rather than `error.span`" is false since predicator
8.0 (`deps/predicator/lib/predicator/errors/parse_error.ex:36` -
`defstruct [:message, :position, span: nil]`). `Map.get/2` is still correct,
for a different struct: `Predicator.Errors.LocationError`
(`deps/predicator/lib/predicator/errors/location_error.ex:64` -
`defstruct [:type, :message, :details]`) has no `:span`, and it is exactly
what `Statifier.Interpreter.Datamodel` hands to `Evaluator.Error.new/2` at
`lib/statifier/interpreter/datamodel.ex:194` and `:250`, wrapping
`Predicator.context_location/2` and `Predicator.ContextLocation.put/3` -
the two ADR-0014 item 4 names beside `Evaluator.evaluate/2`. Name `LocationError`
instead of `ParseError` and keep the rest of the paragraph, including the
ADR-0014 item 4 citation for the nil case.

This is a comment-only edit and carries no test. It ships in this phase rather
than Phase 1 because the investigation that found it is item 4's, and because
`Map.get/2`'s justification is exactly what the new span assertion depends on.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` used between edits (never as the phase gate)
- [x] Full `mix quality` green
- [x] `mix test.regression` passes with the ratchet unchanged
- [x] The new `error.execution` span test passes, and reddens under its stated
      sabotage (revert the Phase 1 swap, observe red, restore)
- [x] `mix quality --profile merge` reports no finding keyed
      `adr-0014-expression-spans` (`lib/mix/statifier/adr_judge.ex:184-186`) -
      this is the bead's own acceptance criterion, and the merge profile is
      the only profile that runs the ADR judge (`.quality.exs`'s
      `adr_judge: [enabled: false]` disables it in the bare gate on purpose,
      and its `profiles: [merge: [adr_judge: [enabled: true]]]` re-enables it;
      see `CLAUDE.md`'s not-applicable-skips section)

#### Manual Verification:

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - no Appendix D procedure is edited in this phase; confirm the
      `error.execution` raise path in
      `lib/statifier/interpreter/content.ex` is unchanged
- [ ] Read the raised event by hand (`mix run` or an iex session) on a
      two-statement failing script and confirm the span underlines the failing
      subexpression rather than the whole program - the ADR-0014 Consequences
      sentence, checked against a real payload
- [ ] `{:system_variable, root}` failures still carry no span and are still
      not wrapped in `Evaluator.Error` - ADR-0014's 2026-08-18 amendment
      requires it, and `test/statifier/evaluator_test.exs:302-360` already
      covers the behavior; confirm those tests were not disturbed

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate, and `mix quality --profile merge` is run once
in this phase to clear the ADR-0014 finding. In interactive execution, pause
here for the human to confirm the manual testing. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement automatically
(via `/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/compiler/expressions_test.exs` - the stored table is a span
  table, not a point table (Phase 1). Edge case: the assertion walks *every*
  entry, so a partially-widened table cannot pass.
- `test/statifier/interpreter/content_test.exs` - `error.execution`'s `data`
  carries a non-nil span naming the failing statement's subexpression
  (Phase 2). Edge cases: the failure is deliberately on the *second* statement,
  so a span that named the whole program or the first statement would fail the
  line assertion. The `<assign>` test just above the `<script>` describe block
  (`test/statifier/interpreter/content_test.exs:454-466`, asserting
  `error_event.data == {:system_variable, "_sessionid"}`) pins the neighboring
  policy-check path that must stay span-free and un-wrapped, and must keep
  passing untouched.
- Existing coverage that must stay green unchanged:
  `test/statifier/machine/content/script_test.exs` (block-level `<script>`
  behavior) and `test/statifier/evaluator_test.exs`'s `run_program/2` and
  protected-root describes.

### Manual Testing Steps:

1. `mix run` a one-liner that compiles `"x = 1;\ny = zzz + 1;"` through
   `Statifier.Compiler.Expressions.compile_program/3` and inspects
   `compiled.positions`; confirm every value is a `{start, stop}` pair and
   that the entry for the final `store` covers the whole second statement.
2. Build a `MachineState` with `"x"`/`"y"` declared, run the program through
   `Statifier.Evaluator.run_program/2`, and inspect the returned
   `%Statifier.Evaluator.Error{}`: `source` is the original program text,
   `error` is predicator's `%UndefinedVariableError{}` verbatim, `span` is
   non-nil.
3. Run the same script through a real document's `<onentry>` and read the
   `error.execution` event off the internal queue; confirm `cause.origin` is
   `{:content, c_index, owner}` and `data` is the same struct.
4. Sabotage check for each new test: revert the Phase 1 swap, confirm both new
   tests go red for the reasons their comments state, restore.

## References

- Bead: `st-57w` (mirrors `px-iov`, closed via predicator PR #157; `px-ehn`
  closed via PR #158)
- Related ADRs: `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
  (items 1, 2, 4 and the 2026-08-15 / 2026-08-18 amendments),
  `docs/adr/0012-*` (item 3, the retained-location constraint),
  `docs/adr/0026-*` (decisions 1, 6, 7 - `<script>` programs and the
  `Evaluator.Error` wrap)
- Predecessor plans: `docs/plans/260815-st-59d-predicator-8-0-bump-structured-compile-errors.md`
  (lines 167-169 and 310 name this bead as the follow-on),
  `docs/plans/260814-st-af3.17-script-statement-bodies.md` (the original
  positions-based wiring)
- Upstream API: `deps/predicator/lib/predicator.ex:856-895`
  (`compile_program_with_spans/1`), `:899-915` (`build_compiled_result/1`)
- Call site: `lib/statifier/compiler/expressions.ex:185-193`
- Payoff chain: `lib/statifier/evaluator.ex:417-465`,
  `lib/statifier/evaluator/error.ex`,
  `lib/statifier/machine/content/script.ex:88-95`,
  `lib/statifier/interpreter/content.ex:266-270`
- ADR judge registry entry: `lib/mix/statifier/adr_judge.ex:184-186`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - vacuously here, since neither `compile_program/3` nor any
      interpreter function it feeds changes shape, but confirm no Appendix D
      procedure was touched
- [ ] The rewritten moduledoc and `@doc` read as a record of a *resolved*
      stopgap, name what closed it (predicator `~> 9.0` /
      `compile_program_with_spans/1`), and quote ADR-0014 item 1 accurately
      against `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
- [ ] No regressions in `<script>` execution: `mix test
      test/statifier/machine/content/script_test.exs
      test/statifier/interpreter/content_test.exs` green

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - no Appendix D procedure is edited in this phase; confirm the
      `error.execution` raise path in
      `lib/statifier/interpreter/content.ex` is unchanged
- [ ] Read the raised event by hand (`mix run` or an iex session) on a
      two-statement failing script and confirm the span underlines the failing
      subexpression rather than the whole program - the ADR-0014 Consequences
      sentence, checked against a real payload
- [ ] `{:system_variable, root}` failures still carry no span and are still
      not wrapped in `Evaluator.Error` - ADR-0014's 2026-08-18 amendment
      requires it, and `test/statifier/evaluator_test.exs:302-360` already
      covers the behavior; confirm those tests were not disturbed

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate, and `mix quality --profile merge` is run once
in this phase to clear the ADR-0014 finding. In interactive execution, pause
here for the human to confirm the manual testing. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement automatically
(via `/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end.

---
