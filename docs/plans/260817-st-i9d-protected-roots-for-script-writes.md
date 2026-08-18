---
date: 2026-08-17
planner: Claude
git_commit: 3a7655a
branch: st-i9d-protected-roots
repository: statifier-ex
beads_issue: st-i9d
topic: "Spec 5.10 for <script> bodies moves from a post-hoc root diff to predicator's protected_roots:, with the diff retained as the residual catch-all"
tags: [plan, datamodel, evaluator, spec-5.10]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# Protected roots for script writes Implementation Plan

## Overview

Consume predicator 9.0's `protected_roots:` option on `Predicator.execute/3`
so a `<script>` body's write to a spec-5.10 system variable **fails at the
attempt** rather than being detected afterwards by diffing context roots.
This closes the two gaps `Statifier.Evaluator.run_program/2`'s docstring
currently records as known and accepted: a later statement in the same body
can observe the write, and a write-then-restore is invisible to the diff.
Beads issue: `st-i9d` (mirrors px-1xy, closed).

## Current State Analysis

**The write site.** `Statifier.Evaluator.run_program/2`
(`lib/statifier/evaluator.ex:385-425`) builds a `Predicator.Context.t()` via
`context/1`, keeps `before_data = predicator_context.data`, calls
`Predicator.execute(compiled, predicator_context)` with **no options**, then
calls `partition_changed_roots/2` (`lib/statifier/evaluator.ex:427-441`) to
split the post-run data's changed roots into `_`-prefixed (system, never
merged, reported as `{:error, machine_state, {:system_variable, root},
post_context}`) and everything else (merged into the raw
`machine_state.datamodel`). `execute/2` (`lib/statifier/evaluator.ex:319-327`)
is a thin wrapper that drops the post context.

**The sibling enforcement, which must stay consistent.**
`Statifier.Interpreter.Datamodel.check_system_variable/1`
(`lib/statifier/interpreter/datamodel.ex:205-215`) enforces 5.10 for
`<assign>`. Its comment states the rule deliberately: a **prefix test on the
resolved root**, not a membership test against the four named variables,
because a prefix test "can never collide with a legitimate author id and
covers `_x` (5.10's platform-variable root) and any future system variable
for free". `Statifier.Machine.Content.Foreach`'s `check_name/2`
(`lib/statifier/machine/content/foreach.ex:160`) applies the same prefix rule
to `item`/`index`, citing the same reason and emitting the same
`{:system_variable, name}` tag. That tag is the shared vocabulary: it becomes
`error.execution`'s `data:` payload identically whichever element attempted
the write (`test/statifier/interpreter/content_test.exs:449-467`).

**The upstream contract, verified against the pinned dep.** `mix.exs:41` pins
`~> 9.0`; `mix.lock` resolves `9.0.0`.

- `deps/predicator/lib/predicator.ex:380-393` documents it: `protected_roots:
  ["_event", ...]` refuses any `store` whose path's **root** segment is in the
  list, stopping the run at that statement with `{:error,
  %Predicator.Errors.EvaluationError{reason: "protected_root"}, context}`,
  `error.details.root` naming the root. Protection is per-root, not per-path.
  The partial context "still carries every write made before the refused
  statement, exactly as any other `store` failure's does."
- `deps/predicator/lib/predicator/evaluator.ex:1553-1573`
  (`store_or_refuse/4`) is the implementation. Its comment: "`store` is the
  only opcode that writes the context (docs/isa.md section 5), so refusing
  here refuses everywhere."
- `deps/predicator/lib/predicator/errors/evaluation_error.ex:82-99` builds the
  error with `details: %{root: root}` explicitly so "a host maps this onto its
  own error vocabulary without matching on `message`".
- **The option reaches a prebuilt `%Predicator.Context{}`.**
  `Predicator.build_evaluator/3` (`deps/predicator/lib/predicator.ex:239-251`)
  reads `protected_roots` from `opts`, not from the context struct
  (`Predicator.Context`'s `defstruct` is `data/functions/on_unbound/host` -
  `deps/predicator/lib/predicator/context.ex:71`). So
  `Predicator.execute(compiled, predicator_context, protected_roots: [...])`
  is the correct call shape, and it does not disturb `run_program/2`'s
  existing "the context's own `functions:`/`on_unbound:` are honored as built"
  property.
- `protected_roots_from_opts/1`
  (`deps/predicator/lib/predicator/evaluator.ex:273-290`) raises
  `ArgumentError` unless the value is a list of binaries.

**What is missing.** `grep protected_roots lib/` returns nothing.

## Desired End State

`run_program/2` passes a `protected_roots:` list to `Predicator.execute/3`, so
a `<script>` write to a protected root never happens and no later statement in
the same body runs. The `{:system_variable, root}` reason tuple is produced
from the upstream `EvaluationError`, so `error.execution`'s `data:` payload is
unchanged. `partition_changed_roots/2` survives, demoted from *the*
enforcement mechanism to the residual catch-all for the one case
`protected_roots:` structurally cannot cover. `run_program/2`'s docstring no
longer records a gap.

Verified by: the new write-then-restore test and the new
later-statement-does-not-observe test go red under their sabotage mutations
and green otherwise; the four existing `<script>` 5.10 tests still assert the
same `{:system_variable, root}` tuple; full `mix quality` green.

### Key Discoveries:

- `lib/statifier/evaluator.ex:356-368` - the "Known and accepted gap"
  paragraph is the **only** place in `lib/` this gap is written down. `grep`
  for "accepted gap" / "pre-execution scan" finds no other lib-side copy, so
  the docstring rewrite is a single-site edit.
- `docs/plans/260814-st-af3.17-script-statement-bodies.md:223-241` (Decision
  4) and `:871-883` (resolved open question 2) both record the gap as
  accepted, and OQ2 names the fix precisely: "Exact semantics need a
  protected-roots hook inside predicator's `store`. Owner: a predicator-side
  bead, mirrored here when it is filed." That bead was px-1xy; this plan is
  its statifier half. Both passages owe a dated amendment note.
- **ADR-0026 does not record the gap.** Grepping
  `docs/adr/0026-script-as-predicator-statement-programs.md` for "gap",
  "5.10", "system variable", "protected" returns nothing on point; its
  Consequences cover the mid-program-failure retention rule
  (`:157-160`), which this plan preserves rather than changes. No new ADR is
  owed either - the direction (an upstream protected-roots hook closes the
  gap) was already chosen by the plan doc's OQ2; this plan implements it and
  does not re-argue it. **ADR-0014 is a different matter and does owe an
  amendment** - see the next bullet.
- **ADR-0014 item 4's 2026-08-15 amendment states a mechanical test this
  change makes false.** It says the item "reaches an `error.execution` exactly
  when a predicator call itself returned `{:error, error}` -
  `Statifier.Evaluator.evaluate/2`, `Predicator.context_location/2`,
  `Predicator.ContextLocation.put/3` - and the payload then wraps that struct
  verbatim via `Statifier.Evaluator.Error`", reserving the bare policy tuples
  for checks "applied *after* predicator succeeded"
  (`docs/adr/0014-expression-spans-in-cond-diagnostics.md:95-121`). Today
  `{:system_variable, root}` sits cleanly on the policy side. After this
  change it no longer does for the `<script>` path: predicator *itself*
  returns an error struct, yet the payload must stay the bare tuple. Resolved
  under "Mapping the upstream error", and the ADR is amended in Phase 2.
- `docs/datamodel.md:196-201` (upstreaming seam 4, "Statement sequences")
  is where predicator statement support is tracked as landed; it is the
  natural home for a one-sentence note that the protected-roots half landed
  in 9.0 and is consumed here.
- **An existing test's expectation genuinely changes.**
  `test/statifier/evaluator_test.exs:305-315` runs `"_event = 1; x = 2;"` and
  asserts `new_ms.datamodel["x"] == 2`. Under `protected_roots:` the program
  halts at statement 1, so `x = 2` never runs and `x` keeps its seeded `nil`.
  That is the fix, not a regression: spec 4.9's stop-and-keep model still
  holds, but the "keep" set shrinks because the failing statement now fails
  *before* the statements after it, instead of after them. The test and its
  sabotage line must be rewritten to assert the new, stronger behavior.
- `Statifier.Evaluator.SystemVariables.initial/2`
  (`lib/statifier/evaluator/system_variables.ex:76-86`) is the single seeder
  of `_sessionid`, `_name`, `_event`, `_ioprocessors`, and
  `MachineState.new/2` merges it **over** the author datamodel
  (`lib/statifier/machine_state.ex:418,448`). So all four are present in the
  pre-run context of every `MachineState`-derived run, by construction - which
  is what lets the derived list cover them without naming them.

## What We're NOT Doing

- **Not weakening the `_`-prefix rule anywhere.**
  `Interpreter.Datamodel.check_system_variable/1` and `Foreach.check_name/2`
  are untouched. Their prefix test stays the repo's rule; this plan makes
  `<script>` reach the same rule by a stronger mechanism, not a narrower one.
- **Not dropping `partition_changed_roots/2`.** See the Implementation
  Approach for why the diff is load-bearing for exactly one residual case.
- **Not touching the conformance corpus or the ratchet.** Every 5.10 corpus
  test writes via `<assign>`, which `check_system_variable/1` already catches
  at the same granularity; no corpus file can observe this change. See
  `## Corpus/Ratchet Notes`.
- **Not writing a changelog fragment.** `changelog.d/README.md`'s v2 rule is
  "write a fragment when v2 differs from v1", and `<script>` statement bodies
  are themselves unreleased v2 work (ADR-0026). This tightens unreleased
  behavior; no 1.x user can observe a difference.
- **Not filing or amending an ADR.** Reasoning above under Key Discoveries.
- **Not adopting `protected_roots:` for `evaluate/2`.** `Predicator.evaluate/3`
  never runs a `store` (`deps/predicator/lib/predicator.ex:376-378` says so in
  as many words), so the option is inert there.
- **Not making the protected list configurable or a `Machine` field.** It is
  derived per run from data already in hand; a knob would be an API surface
  nothing asks for.

## Implementation Approach

### The central tension, and how this plan resolves it

`check_system_variable/1` is a **prefix test on `_`**. Upstream's
`protected_roots:` is a **membership list of binaries** with no prefix mode
(`store_or_refuse/4`'s `if root in roots`,
`deps/predicator/lib/predicator/evaluator.ex:1567`). So the bead's suggested
fixed list (`_event`, `_sessionid`, `_name`, `_ioprocessors`) is strictly
narrower than the rule this repo enforces everywhere else, and adopting it
alone would silently stop catching a write to `_x` or any other `_`-prefixed
root - a weakening this plan refuses.

**Decision: derive the list per run from the roots the context actually
carries, and keep the post-hoc diff as the residual catch-all.**

```
protected_roots = [root for root in before_data if root starts_with "_"]
```

Rationale, in the order that matters:

1. **The union of the two mechanisms is complete, not merely broad.** Split
   the `_`-prefixed roots a program can write into two classes:

   - **Roots present before the run.** Every one of them is in the derived
     list, so every write to one is refused at the attempt. Both old gaps -
     later statements observing the write, and write-then-restore - are gone
     for this class, because no write ever lands.
   - **Roots the program creates fresh** (`_foo = 1` where `_foo` was absent).
     These are exactly the ones the derived list misses. But `store` **never
     deletes a root** (`run_program/2`'s own docstring already states this,
     and predicator's `ContextLocation.put/3` has no removal path), so a
     freshly created root can never be restored to absence. It is therefore
     *always* visible to `partition_changed_roots/2`: the root is absent from
     `before_data`, so it diffs against the `:__absent__` sentinel and counts
     as changed for any value predicator can produce. Write-then-restore is
     structurally impossible for this class.

   So the residual blind spot of the combined mechanism is empty. That is a
   stronger claim than "belt and braces" and is the reason the diff is
   retained rather than dropped.

2. **The two named alternatives are both worse.** A fixed four-element list
   alone narrows the rule (loses `_x`). Enumerating context roots alone
   (without the diff) loses program-created `_` roots entirely - today's diff
   catches those, so that option would be a net regression against the
   current code.

3. **The four named 5.10 variables need no separate floor, and adding one
   would be unreddenable code.** The obvious extra safety - unioning a fixed
   `["_event", "_sessionid", "_name", "_ioprocessors"]` in, so an unseeded
   datamodel still protects them - is provably redundant here.
   `Statifier.MachineState.new/2` merges `SystemVariables.initial/2`
   **over** the author datamodel (`lib/statifier/machine_state.ex:448`, and
   its own doc at `:418` says so), so every `MachineState` carries all four
   by construction and the derived list already contains all four. A union
   term that no input can make load-bearing is a branch no test could
   redden, which this repo's sabotage rule (CLAUDE.md, `docs/testing.md`)
   treats as a defect rather than as caution. And the case it would guard -
   a hand-built `%MachineState{}` with the keys stripped - is not a gap
   anyway: a write to a `_` root absent from `before_data` creates it fresh,
   which is class two above, which the diff catches. **So no
   `SystemVariables.roots/0` is added and `SystemVariables` is not touched
   by this plan.**

4. **Cost is bounded by datamodel size, once per program run.** One filter
   over `before_data` - the same map `partition_changed_roots/2` already
   traverses. `<script>` is not a hot path (one program per `<script>` node
   execution). See `## Performance Considerations`.

**Consequence for the post-hoc check, decided here rather than
independently:** `partition_changed_roots/2` is **kept, unchanged in code**,
and **re-documented** as the catch-all for program-created `_` roots. Its
`system_changed` branch in `run_program/2`'s `cond` also stays. What changes
is only what the comments and the docstring claim it is for.

### Error-arm ordering, decided explicitly

`run_program/2`'s `cond` checks `run_error != nil` before `map_size(
system_changed) > 0`. Keep that order, and map the protected-root error inside
the `run_error` arm. One edge case follows and is documented rather than
special-cased: a program that first creates a fresh `_foo` and *then* writes
`_event` produces both a `system_changed` entry and a protected-root
`run_error`. The reported root is `_event` (the statement that halted the
run). This is safe because `_foo` is still in `system_changed` and therefore
still never merged - only the root *named* in the reason tuple differs, and
either name is a truthful `{:system_variable, _}`. Adding a tie-break rule
would be code for a case no document produces.

### Mapping the upstream error

Match on the struct, not the message (upstream's own instruction):

```elixir
{:error, %Predicator.Errors.EvaluationError{reason: "protected_root", details: %{root: root}},
 %Predicator.Context{} = post_context} ->
  # -> {:system_variable, root}
```

Every other `{:error, error, post_context}` keeps its existing
`Error.new(source, error)` wrap (ADR-0026 decision 6).

**Why this does not follow ADR-0014 item 4's wrap-verbatim rule, and what
the ADR owes as a result.** Item 4's 2026-08-15 amendment draws the line at
the predicator seam: an `error.execution` whose trigger is "a predicator call
itself returned `{:error, error}`" wraps that struct verbatim through
`Evaluator.Error`, while a check "applied *after* predicator succeeded" is
not an expression failure and carries a bare policy tuple instead. Read
mechanically, a protected-root refusal now satisfies the *first* test -
predicator returned an error struct - so item 4 would appear to demand
`Error.new(source, error)` here.

That reading is rejected, on the amendment's own reasoning rather than
against it:

- **The amendment's test enumerates three call sites, and
  `Predicator.execute/3` is not one of them.** It names
  `Statifier.Evaluator.evaluate/2`, `Predicator.context_location/2`, and
  `Predicator.ContextLocation.put/3`. Statement-program execution was not in
  scope when the line was drawn, and the protected-roots option did not exist
  in the pinned dependency.
- **The policy is statifier's, merely enforced upstream.** The refusal
  happens because *this repo* passed `protected_roots:`; predicator has no
  opinion about `_`-prefixed roots and would have performed the write
  happily. The error struct is upstream's report of executing a host policy,
  not upstream's judgment that the expression was bad. That is exactly the
  "engine policy check" the amendment means to keep off the expression layer;
  the option's arrival merely moved *where* the same engine policy runs, from
  after the call to inside it.
- **The amendment's substantive reason still holds verbatim.** It justifies
  the bare tuple by observing there is "no failing *subexpression* for a span
  to underline - the culprit is the resolved root or the whole path, and the
  tuple names it directly, which is the whole diagnostic." That is equally
  true here: the culprit is the root, `details.root` names it, and no
  subexpression failed. Wrapping would ship a payload whose span points at a
  statement that is syntactically and semantically fine.
- **The alternative breaks the bead's one stated non-regression.** Wrapping
  would make `error.execution`'s `data:` an `%Evaluator.Error{}` for
  `<script>` while `<assign>` keeps `{:system_variable, root}` - the exact
  divergence the bead's acceptance criteria forbid, and which
  `test/statifier/interpreter/content_test.exs:465` pins.

**Decision: the protected-root refusal joins the policy-tuple bucket, and
ADR-0014 item 4 is amended to say so** (Phase 2, item 3), because its
current text states a mechanical test that this change makes false. Leaving
the ADR unamended while writing code the ADR's literal words forbid is the
"silent departure from a settled decision" this repo's conventions exist to
prevent. The amendment adds a third member to the policy-tuple list and
narrows the "predicator returned an error" test to "predicator returned an
error *of its own judgment*"; it does not touch item 4's Decision sentence,
so it is an amendment rather than a supersession, in the form ADR-0014
already carries two of.

### Appendix D note

`run_program/2` is not an Appendix D procedure - it is the evaluation seam
behind `Interpreter.Content`'s `<script>` handling. No Appendix D pseudocode
is ported or deviated from by this plan. The spec text in play is 5.10
("system variables ... the SCXML Processor MUST NOT allow ... to be modified")
and 4.9's stop-and-keep model, both of which the change moves *toward*.

---

### Recorded for human confirmation (no human was available at planning time)

Every design question this plan raises is **decided**, not deferred - nothing
below blocks implementation. Two of the decisions are judgment calls a human
may want to revisit, and they are named here so they are not discovered as
surprises in review:

1. **Amending ADR-0014 item 4 rather than following its literal text.**
   Argued in full under "Mapping the upstream error". The alternative -
   wrapping the protected-root refusal through `Evaluator.Error` - is
   internally consistent with the ADR's mechanical wording but breaks the
   `data:` payload parity the bead names as its one non-regression, so the
   plan amends the ADR instead. An ADR amendment is normally a human's call;
   this plan drafts the amendment and the wording, and a human should confirm
   it before Phase 2 lands. If the answer is "wrap it verbatim after all",
   that is a change to the bead's acceptance criteria, not just to this plan.
2. **Retaining `partition_changed_roots/2` rather than dropping it.** The
   bead left this open ("Demote ... or drop. Decide which when the upstream
   error shape is known"). The plan retains it, on the argument that it is the
   only thing covering program-created `_` roots. That argument is spelled out
   so it can be checked rather than taken on trust.

---

## Phase 1: Refuse the write at the attempt

### Overview

Pass a derived `protected_roots:` list to `Predicator.execute/3`, map the
resulting `EvaluationError` onto `{:system_variable, root}`, rewrite the
docstring, and prove both previously-uncatchable cases with tests. This is one
phase because the mechanism, the changed expectation of an existing test, and
the docstring that describes the mechanism cannot leave the gate green if
split apart.

### Changes Required:

#### 1. Pass and derive the protected list

**File**: `lib/statifier/evaluator.ex`
**Changes**: in `run_program/2`, compute the list and pass it; add the
private helper.

```elixir
{post_context, run_error} =
  case Predicator.execute(compiled, predicator_context,
         protected_roots: protected_roots(before_data)
       ) do
    {:ok, %Predicator.Context{} = post_context} ->
      {post_context, nil}

    {:error,
     %Predicator.Errors.EvaluationError{reason: "protected_root", details: %{root: root}},
     %Predicator.Context{} = post_context} ->
      {post_context, {:system_variable, root}}

    {:error, error, %Predicator.Context{} = post_context} ->
      {post_context, error}
  end
```

and, in the `cond`, distinguish the already-mapped reason from an
`Evaluator.Error`-wrappable one:

```elixir
cond do
  match?({:system_variable, _root}, run_error) ->
    {:error, new_machine_state, run_error, post_context}

  run_error != nil ->
    {:error, new_machine_state, Error.new(source, run_error), post_context}

  map_size(system_changed) > 0 ->
    [{root, _value} | _rest] = Enum.sort(system_changed)
    {:error, new_machine_state, {:system_variable, root}, post_context}

  true ->
    {:ok, new_machine_state, post_context}
end
```

The helper, with the comment carrying the prefix-vs-membership reasoning:

```elixir
# Spec 5.10's rule in this repo is a *prefix* test on `_`
# (`Statifier.Interpreter.Datamodel.check_system_variable/1`), and
# predicator's `protected_roots:` is a *membership* list of binaries with
# no prefix mode (`deps/predicator/lib/predicator/evaluator.ex:1567`). So
# the list is derived per run from the roots the context already carries.
# It covers all four 5.10 variables without naming them:
# `MachineState.new/2` merges `SystemVariables.initial/2` over the author
# datamodel, so every one of them is in `before_data` by construction.
# The roots this list cannot name are exactly those a program creates
# fresh - and `store` never deletes, so a fresh `_` root can never be
# restored to absence and is therefore always visible to
# `partition_changed_roots/2` below. The two together leave no residual
# case.
@spec protected_roots(before_data :: map()) :: [String.t()]
defp protected_roots(before_data) do
  for {root, _value} <- before_data,
      String.starts_with?(root, "_"),
      do: root
end
```

**Alias note**: `Statifier.Evaluator` aliases only
`Statifier.Evaluator.{Error, Functions}`, `Statifier.Machine`, and
`Statifier.MachineState` (`lib/statifier/evaluator.ex:140-143`). Add
`alias Predicator.Errors.EvaluationError` so the match reads
`%EvaluationError{}` - Credo's nested-alias rule prefers it, and the
alphabetical position is above the `Statifier.*` block.

**Wrapping note**: `Statifier.Evaluator.Error`'s own moduledoc
(`lib/statifier/evaluator/error.ex:10`) lists `%Predicator.Errors.
EvaluationError{}` among the shapes it wraps. The `reason: "protected_root"`
clause must therefore come **before** the general `{:error, error,
post_context}` clause, or a protected-root refusal would be wrapped as a
generic `Evaluator.Error` and `error.execution`'s `data:` payload would
silently change shape - the one thing the bead names as not to regress.

**Type note**: `run_program/2`'s `@spec` already admits
`Error.t() | {:system_variable, String.t()}` in the error position, so no
spec widening is owed. Confirm Dialyzer agrees - the `run_error` local now
holds a union of `nil | struct() | {:system_variable, String.t()}`.

#### 2. Rewrite the docstring

**File**: `lib/statifier/evaluator.ex` (`run_program/2`'s `@doc`)
**Changes**: delete the "Known and accepted gap" paragraph
(`:356-368`) whole, including the pre-execution-scan reasoning and the
closing "which is upstream work" sentence, and replace the surrounding
system-variable paragraph with prose describing the new two-part mechanism.
The replacement must say:

- `protected_roots:` is passed to `Predicator.execute/3`, so a write to a
  protected root **fails at the attempt**: the run halts at that statement,
  no later statement in the body runs, and a write-then-restore cannot hide
  because no write lands.
- The list is derived (prefix rule reconciled against a membership API) -
  point at the helper rather than restating its comment.
- The diff's remaining job is program-created `_` roots, plus the
  `store`-never-deletes argument that makes that class fully covered.
- The reason tuple is still `{:system_variable, root}`, still identical to
  `Statifier.Interpreter.Datamodel.check_system_variable/1`'s, so
  `error.execution`'s `data:` is unchanged. (Note: the current docstring
  cites this as `Statifier.Machine.Content.Assign.check_system_variable/1`;
  the function now lives at
  `lib/statifier/interpreter/datamodel.ex:205`. Correct the reference while
  here. The stale name also appears at
  `lib/statifier/machine/content/foreach.ex:152`; leave that one alone - it
  is outside this bead and outside this diff's file set.)
- Non-system writes made *before* the refused statement still merge, spec
  4.9's stop-and-keep model - now applied at the statement that failed rather
  than after the whole program.
- The both-arms edge case and why `_event` is the reported root there.

#### 3. Update the changed-expectation test

**File**: `test/statifier/evaluator_test.exs` (`:305-315`)
**Changes**: the `"_event = 1; x = 2;"` test now asserts the *stronger*
outcome. Rewrite it and its sabotage line:

```elixir
# sabotage: drop the `protected_roots:` option from `run_program/2`'s
# `Predicator.execute/3` call -> `_event = 1` succeeds inside the program,
# `x = 2` runs after it, and `new_ms.datamodel["x"] == nil` reddens
# (the post-hoc diff still reports `{:system_variable, "_event"}`, so only
# the halt assertion catches it).
test "a system-variable write halts the program at the attempt" do
  ms = new_machine_state(datamodel: %{"x" => nil})

  assert {:error, new_ms, {:system_variable, "_event"}} =
           Evaluator.execute(ms, program("_event = 1; x = 2;"))

  assert new_ms.datamodel["x"] == nil
  assert new_ms.datamodel["_event"] == :undefined
end
```

The assertion is `== nil`, not `== :undefined`: `MachineState.new/2` merges
the author datamodel unchanged (`lib/statifier/machine_state.ex:436,448` -
only `SystemVariables.initial/2` is merged *over* it), and a root the program
never wrote is never merged back, so `"x"` keeps the raw `nil` it was seeded
with. Confirm against the actual run before committing the assertion.

Also confirm the still-passing shape of a *non-protected* mid-program failure
(`evaluator_test.exs:281-290`), which is unaffected.

#### 4. The new tests the bead exists for

**File**: `test/statifier/evaluator_test.exs`, in the `execute/2` describe.

```elixir
# AC (st-i9d): the case the post-hoc diff structurally cannot see - a
# write to a protected root followed by a write of the original value
# back. Under the diff alone, `_name` is byte-identical before and after,
# so nothing is reported at all.
#
# sabotage: drop the `protected_roots:` option from `run_program/2`'s
# `Predicator.execute/3` call -> `partition_changed_roots/2` sees `_name`
# unchanged, `run_program/2` returns `{:ok, _, _}`, and this test's
# `{:error, ...}` match reddens.
test "a write-then-restore of a system variable is caught" do
  ms = new_machine_state(datamodel: %{})
  ms = %{ms | datamodel: Map.put(ms.datamodel, "_name", "chart")}

  assert {:error, _new_ms, {:system_variable, "_name"}} =
           Evaluator.execute(ms, program("_name = 'other'; _name = 'chart';"))
end

# AC (st-i9d): 5.10 wants the write to fail *at the attempt*, so a later
# statement in the same body must never read the written value.
#
# sabotage: drop the `protected_roots:` option from `run_program/2`'s
# `Predicator.execute/3` call -> the `_name` write lands inside the
# program, `seen` reads 'other' and merges as a non-system root, so
# `new_ms.datamodel["seen"] == nil` reddens.
test "a later statement in the same body does not observe the write" do
  ms = new_machine_state(datamodel: %{"seen" => nil})
  ms = %{ms | datamodel: Map.put(ms.datamodel, "_name", "chart")}

  assert {:error, new_ms, {:system_variable, "_name"}} =
           Evaluator.execute(ms, program("_name = 'other'; seen = _name;"))

  assert new_ms.datamodel["seen"] == nil
end
```

Both fixtures overwrite the already-seeded `_name`
(`MachineState.new/2` seeds it via `SystemVariables.initial/2`) with a known
value, so the restore target is unambiguous. Add one more covering the branch
this plan deliberately keeps alive - the residual diff, reached only by a root
the program creates fresh, which `protected_roots/1` structurally cannot name:

```elixir
# AC (st-i9d): the one case `protected_roots:` cannot cover - a `_` root
# absent from the pre-run context, so the derived list never names it.
# `partition_changed_roots/2` is retained exactly for this, and this test
# is what would notice if it were dropped as "belt and braces".
#
# sabotage: delete the `map_size(system_changed) > 0` arm from
# `run_program/2`'s `cond` -> the program succeeds, `_created` merges into
# the datamodel, and the `{:error, ...}` match reddens.
test "a program-created _ root is still caught by the retained diff" do
  ms = new_machine_state(datamodel: %{})

  assert {:error, new_ms, {:system_variable, "_created"}} =
           Evaluator.execute(ms, program("_created = 1;"))

  refute Map.has_key?(new_ms.datamodel, "_created")
end
```

Every one of these is a `lib/`-behavior assertion, so each carries its
sabotage line per CLAUDE.md and `docs/testing.md`. **Actually run each
mutation, confirm red, revert** - the lines above are the intended mutations,
not evidence they redden.

#### 5. Check the block-level path still reports the same payload

**File**: `test/statifier/machine/content/script_test.exs`,
`test/statifier/interpreter/content_test.exs`,
`test/statifier/interpreter/script_acceptance_test.exs`
**Changes**: likely none, but each is read and re-run. The `data:` payload
contract (`content_test.exs:449-467` for `<assign>`) is the thing not to
regress; if a `<script>` block test asserts a merge that a now-halting
program no longer produces, update it the same way item 3 does, with a
rewritten sabotage line.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not a phase gate on
      its own).
- [x] Full `mix quality` green, including Dialyzer over the widened
      `run_error` union and Doctor over the rewritten `@doc`.
- [x] `mix gate.verify` exits zero, proving the run was a full, unscoped,
      un-`--skip`ed gate.
- [x] `grep -n "protected_roots" lib/statifier/evaluator.ex` returns the
      option site and the helper.
- [x] `grep -c "Known and accepted gap" lib/statifier/evaluator.ex` returns 0.
- [x] `grep -c "pre-execution scan" lib/statifier/evaluator.ex` returns 0.
- [x] Each new test's stated sabotage mutation, applied by hand, turns that
      test red; reverted, green.
- [x] `mix test.regression` green (the ratchet is unchanged - see
      `## Corpus/Ratchet Notes`).

#### Manual Verification:
- [ ] Spec judgment: read 5.10 from the local cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`,
      running `mise run spec:fetch` if absent) and confirm the new behavior -
      halt at the attempt, no later statement runs - is what the clause asks
      for, quoting the clause in the commit body. `run_program/2` is not an
      Appendix D procedure, so there is no pseudocode to match line for line;
      the equivalent judgment is this 5.10 reading plus confirming 4.9's
      stop-and-keep still holds for the writes that preceded the refusal.
- [ ] The derived-list argument holds against the code as written: no
      `_`-prefixed root reachable by a program escapes both the list and the
      diff.
- [ ] The rewritten docstring reads as a description of the mechanism, not as
      a diff against the old one - no "previously", no "used to".
- [ ] No regression in `<script>` behavior exercised through
      `Statifier.Interpreter.Content`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Record the closure in the written history

### Overview

The plan document and the datamodel doc both still say the gap stands, and
ADR-0014 item 4 states a boundary test Phase 1 makes false. Amend all three in
the repo's existing form, so the next reader is not sent chasing a fixed
problem or reading a rule the code no longer follows. Docs only; no `lib/`
change, independently committable.

This phase is separable from Phase 1 because nothing in Phase 1 reads these
documents at build or test time. It is nonetheless **not optional**: the
ADR-0014 amendment is the record that Phase 1's error-mapping choice was made
deliberately, and shipping Phase 1 without it is what the "never silently
contradict an accepted ADR" rule forbids. If only one of the two phases can
land, they land together.

### Changes Required:

#### 1. Amend the originating plan document

**File**: `docs/plans/260814-st-af3.17-script-statement-bodies.md`
**Changes**: two dated `**Amendment (st-i9d):**` paragraphs, in the same form
`docs/plans/260817-st-1xwh-initial-datamodel-binding-effect.md` and
`docs/plans/260816-st-oef3-assign-datamodel-change-effect.md` already use.

- Under **Decision 4** (`:223-241`), after the "Known and accepted gap"
  paragraph: state that the gap closed on 2026-08-17 via st-i9d, that
  `protected_roots:` (predicator 9.0) refuses the write at the attempt, and
  that the diff is retained for program-created `_` roots. Do not delete the
  original paragraph - it is the record of what was decided then.
- Under **resolved open question 2** (`:871-883`): note that the named
  upstream owner (px-1xy) shipped and was consumed by st-i9d; the
  "nothing in this repo is blocked meanwhile" reading held.

#### 2. Note the landed seam

**File**: `docs/datamodel.md`
**Changes**: extend upstreaming seam 4 (`:196-201`) with one sentence -
predicator 9.0's `protected_roots:` option on `Predicator.execute/3` is the
5.10 half of the same seam, consumed here by st-i9d, replacing the post-hoc
root diff as the enforcement mechanism.

#### 3. Amend ADR-0014 item 4

**File**: `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
**Changes**: a dated `*(Amended 2026-08-17, st-i9d: ...)*` paragraph appended
to item 4 (after the existing 2026-08-15 amendment paragraph at `:95-121`),
in the same parenthetical-italic form that paragraph already uses. It must:

- Add the protected-root refusal as a **third member** of the policy-tuple
  list, beside `write_location/4`'s two (`{:system_variable, root}` and
  `{:unbound_location, path_source}`).
- Narrow the 2026-08-15 mechanical test. "Predicator returned `{:error,
  error}`" is no longer sufficient on its own, because
  `Predicator.execute/3`'s `protected_roots:` option makes predicator report
  a refusal that is *statifier's* policy, not predicator's judgment about the
  expression. The test becomes whether the error is predicator's own
  evaluation failure; a refusal predicator performed on the host's
  instruction is a policy check that happens to run inside the call.
- Cite the substantive reason unchanged - no failing subexpression, the root
  is the whole diagnostic - so the amendment reads as the existing reasoning
  reaching a case it had not met, not as a new rule.
- Name `Statifier.Evaluator.run_program/2` as the site, and st-i9d as the
  change.

Also update the `Status:` line (`:3`), which already carries its amendment
history inline, to name the 2026-08-17 amendment alongside the 2026-08-15
one.

**Not touched**: item 4's Decision sentence, the Consequences section's
recorded open question about `path_source`, and every other item. This is an
amendment in ADR-0026's stated sense ("Amendment, not supersession",
`docs/adr/0026-*:139-144`), not a supersession, and the paragraph should say
so in as many words.

**File**: `docs/adr/README.md`
**Changes**: ADR-0014's row (`:18`) carries its amendment history in the
status column - today `accepted (amended 2026-08-15: item 4 stops at the
predicator seam; engine policy checks are not expression failures)`. Extend
it with the 2026-08-17 amendment in the same form, so the table and the ADR's
own `Status:` line stay in step.

Typography: `docs/datamodel.md`, the st-af3.17 plan, ADR-0014, and this plan
are all hyphen-only ASCII (`grep -c '—\|–'` returns 0 on each), so the amendments use
plain hyphens and need no house-style adjustment. Do not make a conversion
pass over any of them.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green (the ADR guard and any markdown stages run over
      a docs-only diff; no `lib/` file is touched, so `mix adr.check` passes
      trivially).
- [ ] `mix gate.verify` exits zero.
- [ ] `grep -c "Amendment (st-i9d)" docs/plans/260814-st-af3.17-script-statement-bodies.md`
      returns 2.
- [ ] `grep -c "protected_roots" docs/datamodel.md` returns at least 1.
- [ ] `grep -c "st-i9d" docs/adr/0014-expression-spans-in-cond-diagnostics.md`
      returns at least 1, and `grep -n "2026-08-17"` matches both that file's
      `Status:` line and ADR-0014's row in `docs/adr/README.md`.
- [ ] `git diff --stat docs/adr/` lists only
      `0014-expression-spans-in-cond-diagnostics.md` and `README.md` - no
      other ADR is touched.

#### Manual Verification:
- [ ] The amendments read as additions to a historical record, not as edits
      that rewrite what was decided in August.
- [ ] ADR-0026's text is byte-identical on this branch - the only ADR this
      plan amends is 0014, and only its item 4 and `Status:` line.
- [ ] The ADR-0014 amendment reads as the existing reasoning meeting a case
      it had not met, not as a new rule invented to license Phase 1's code.
      This is the judgment call a human should confirm; see the note under
      "Mapping the upstream error".

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

**No corpus movement is expected or promised.** Every W3C 5.10 test writes via
`<assign>` (the 5.8/5.10 family the corpus carries), which
`Statifier.Interpreter.Datamodel.check_system_variable/1` already refuses at
the attempt - `<assign>` resolves and checks its location *before* writing, so
it never had either gap. The `<script>`-bearing corpus files are
`test/scxml_tests/mandatory/script/test30{2,3,4}_test.exs` and
`test/scion_tests/script/test{1,2}_test.exs`; grepping all five for `_event`,
`_name`, `_sessionid`, and `_ioprocessors` returns nothing, so no corpus
document contains a `<script>` body that writes a system variable, let alone
one that restores it. Re-run that grep at implementation time - a corpus
regeneration in between could in principle add one. `mix test.regression`
must stay green; `test/passing_tests.json` must be unchanged, and
`mix test.baseline add` must **not** be run for this bead. A ratchet change
appearing on this branch is a signal something else moved, not a win.

## Performance Considerations

`protected_roots/1` adds one comprehension over `before_data` per program run,
building a list whose length is the number of `_`-prefixed roots (four in
every realistic document). `before_data` is the whole
bound datamodel, the same map `partition_changed_roots/2` already walks once
per run, so this is a constant-factor addition on a path that already scales
with datamodel size, on a per-`<script>`-execution frequency (not
per-expression, not per-microstep). Upstream's own cost is a
`root in roots` membership test per `store`, over a list whose length is the
number of `_`-prefixed roots - single digits in every realistic document.

No benchmark re-run is owed: `bench/macrostep.exs` and `bench/context_build.exs`
measure context construction and macrostep cost, neither of which runs a
`<script>` program.

## Testing Strategy

### Unit Tests:
- `test/statifier/evaluator_test.exs`, `execute/2` describe: write-then-restore
  caught; later statement does not observe the write; a program-created `_`
  root still caught by the retained diff; the rewritten halt-at-the-attempt
  test replacing the old `"_event = 1; x = 2;"` merge expectation.
- Edge cases to cover or consciously skip: a nested protected write
  (`_event.name = 1`) is refused for the same root, per upstream's per-root
  rule - worth one assertion since it is the shape `<assign>`'s own tests use
  (`assign_test.exs:152`).

### Manual Testing Steps:
1. Read spec 5.10 from the local cache and confirm the halt-at-the-attempt
   reading, quoting the clause.
2. In `iex -S mix`, build a `MachineState` seeded via
   `SystemVariables.initial/2`, run
   `Evaluator.execute(ms, program("_event = 1; x = 2;"))`, and confirm the
   returned datamodel shows `x` untouched and the reason tuple is
   `{:system_variable, "_event"}`.
3. Run the same program with the `protected_roots:` option removed by hand and
   confirm the old, weaker behavior returns - this is the sabotage proof for
   the phase's central change.
4. Run a full `<script>` document through `Statifier.Session` and confirm the
   queued `error.execution` carries `data == {:system_variable, "_event"}`,
   identical to the `<assign>` case in `content_test.exs:449-467`.

## References

- Bead: `st-i9d` (mirrors `px-1xy`, closed; shipped in predicator 8.0.0, this
  repo now pins `~> 9.0`)
- Source document: `docs/plans/260814-st-af3.17-script-statement-bodies.md`
  (Decision 4 at `:223-241`, resolved open question 2 at `:871-883`) - amended
  by this plan
- `docs/research/260814-st-af3.17-script-statement-bodies.md:715-730` - the
  original pre-execution-scan analysis
- Related ADRs: `docs/adr/0026-script-as-predicator-statement-programs.md`
  (`<script>` as predicator statement programs; **not** amended by this plan),
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md` (expression-level
  spans; its 2026-08-15 item-4 amendment on wrap-verbatim vs policy-tuple is
  directly in play here and **is** amended by this plan - see "Mapping the
  upstream error"),
  `docs/adr/0028-executable-content-blocks-thread-one-context.md`
  (the post-context threading `run_program/2` serves)
- Write site: `lib/statifier/evaluator.ex:319-441`
- Sibling enforcement to stay consistent with:
  `lib/statifier/interpreter/datamodel.ex:205-215`,
  `lib/statifier/machine/content/foreach.ex:152-164`
- Upstream contract: `deps/predicator/lib/predicator.ex:380-393`,
  `deps/predicator/lib/predicator/evaluator.ex:1553-1573`,
  `deps/predicator/lib/predicator/errors/evaluation_error.ex:82-99`
- `docs/datamodel.md:196-201` (upstreaming seam 4) - amended by this plan
- Payload-equivalence test to not regress:
  `test/statifier/interpreter/content_test.exs:449-467`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec judgment: read 5.10 from the local cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`,
      running `mise run spec:fetch` if absent) and confirm the new behavior -
      halt at the attempt, no later statement runs - is what the clause asks
      for, quoting the clause in the commit body. `run_program/2` is not an
      Appendix D procedure, so there is no pseudocode to match line for line;
      the equivalent judgment is this 5.10 reading plus confirming 4.9's
      stop-and-keep still holds for the writes that preceded the refusal.
- [ ] The derived-list argument holds against the code as written: no
      `_`-prefixed root reachable by a program escapes both the list and the
      diff.
- [ ] The rewritten docstring reads as a description of the mechanism, not as
      a diff against the old one - no "previously", no "used to".
- [ ] No regression in `<script>` behavior exercised through
      `Statifier.Interpreter.Content`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
