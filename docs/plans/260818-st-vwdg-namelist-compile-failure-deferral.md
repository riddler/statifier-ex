# Namelist Compile-Failure Deferral Implementation Plan

## Overview

A `namelist` entry that fails to compile as a predicator expression currently
fails `Statifier.Compiler.compile/1`, so the whole document is unloadable. This
plan moves that failure from load time to evaluation time: the compile error is
captured as `{:invalid, error}` on the entry's `%Statifier.Machine.Param{}` -
the shape `<data expr>`, `<assign expr>` and both `<script>` forms already use -
and the `<send>` / `<invoke>` argument-resolution folds short-circuit it into
the `error.execution` that ADR-0036 and ADR-0031 already specify. Nothing about
the runtime half changes behavior; it simply stops being preempted.

Bead: st-vwdg. Source research:
`docs/research/260818-st-vwdg-namelist-compile-failure-deferral.md`.

## Current State Analysis

**The bead's stated diagnosis is wrong in one respect, and the plan does not
follow it.** The bead says a `namelist` token "should never reach the predicator
compiler as an expression string at all". Spec 6.2.2 and 6.4.1 both type
`namelist` as a "List of location expressions" with the constraint "List of
valid location expressions", pointing at 5.9.2 Location Expressions. The entries
genuinely are expressions, so compiling them is correct. The defect is *when* a
bad one is rejected.

What exists today:

- **Lowering** whitespace-splits the attribute into `[String.t()]`
  (`lib/statifier/lowering/attributes.ex:39-48`, call sites
  `lib/statifier/lowering/builders.ex:837` and `:892`). One shared span is
  recorded for the whole attribute, not per token. No syntax check here.
- **Compile - `<send>`**: `build_send_namelist/3`
  (`lib/statifier/compiler.ex:1153-1164`) maps each entry through
  `build_param/6` (`:1431-1454`) with `kind: :location`, the entry text doing
  double duty as `MParam.name` and as the source to compile, then `collect/1`s
  the results. It is the last clause of `build_content_node/2`'s `with`
  (`:1007-1037`), which has no `else`, so one bad entry returns
  `{:error, errors}` for the whole `%MSend{}`.
- **Compile - `<invoke>`**: `build_invoke_namelist/4`
  (`lib/statifier/compiler.ex:1600-1618`) routes each `build_param/6` result
  through `collect_invoke_param/2` (`:1620-1627`), which pushes the error onto
  `acc.invoke_errors` and returns `nil`; the failing entry is then **dropped**
  by `Enum.reject(&is_nil/1)` (`:1617`). `compile/1` concatenates
  `acc.invoke_errors` into its error merge (`:269`) and returns `{:error,
  errors}` (`:304-306`).
- **Runtime - `<send>`**: `Machine.Content.Send.execute/2`
  (`lib/statifier/machine/content/send.ex:111-147`) resolves
  `node.namelist ++ node.params` through its own `resolve_params/2`
  (`:297-312`), halting on the first `{:error, reason}`; the block runner
  converts that to `error.execution`
  (`lib/statifier/interpreter/content.ex:219-220`, `:283-299`) and no
  `Effect.Send` is produced. This is ADR-0036, implemented.
- **Runtime - `<invoke>`**: `invoke_one/6`
  (`lib/statifier/interpreter.ex:1362-1418`) resolves
  `invoke.namelist ++ invoke.params` through `resolve_params/2` (`:1434-1449`),
  same halt shape, and its `else` calls `abort_invocation/4` (`:1618-1631`),
  raising `error.execution` with origin `{:invoke, state_index, invoke_index}`
  and producing no `Effect.Invoke`. This is ADR-0031, implemented.
- **Runtime - finalize**: `auto_assign_finalize/5`
  (`lib/statifier/interpreter.ex:735-759`) filters
  `invoke.namelist ++ invoke.params` to `kind == :location` and writes each
  event-data name match through `write_finalize_target/6` (`:784-799`), which
  pattern-matches `%Param{expr: {:compiled, _compiled, source}}`.
- **Evaluator** has no `{:invalid, _}` clause at all
  (`lib/statifier/evaluator.ex:277-287`, `:415-429`); every existing consumer
  of the shape intercepts it before the evaluator would see it
  (`lib/statifier/machine/content/assign.ex:118`,
  `lib/statifier/machine/content/script.ex:68`,
  `lib/statifier/interpreter/datamodel.ex:379-381`,
  `lib/statifier/interpreter.ex:378-383`).
- **Validator** says nothing about entry syntax: the only two `namelist` checks
  are co-occurrence checks (`lib/statifier/validator/checks/send.ex:217-222`,
  `lib/statifier/validator/checks/invoke.ex:100-105`). Entry syntax is not a
  validation concern under this project's layering, and this plan does not make
  it one.
- **The two corpus tests**: `test/scxml_tests/mandatory/send/test553_test.exs`
  and `test/scxml_tests/mandatory/invoke/test554_test.exs` both carry
  `namelist="&quot;foo"` (four characters, `"foo`) and both expect `["pass"]`,
  which is only reachable if the send is discarded / the invocation abandoned.
  Both currently flunk in `Statifier.Case.parse_document/1`
  (`test/support/case.ex:362-367`) with a byte-identical
  `failed to compile expression "\"foo": Unterminated double-quoted string
  literal`. Neither is in `test/passing_tests.json`, neither is excluded, and
  both are already mapped to st-vwdg by the st-cmq.9 red-to-bead ledger
  (`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1301-1310`).

## Desired End State

A document whose `namelist` contains a syntactically ill-formed location
expression **loads**. `Statifier.Compiler.compile/1` returns `{:ok, machine}`
with `{:invalid, %Compiler.Error{}}` on that entry's `%Machine.Param{}`.
Evaluating that `<send>` raises `error.execution` and produces no
`Effect.Send`/`Effect.SendDelayed`; executing that `<invoke>` raises
`error.execution` with origin `{:invoke, state_index, invoke_index}` and
produces no `Effect.Invoke`. test553 and test554 pass and are ratcheted into
`test/passing_tests.json`.

Verification: `mix quality` green at every phase, `mix test --include scxml_w3
test/scxml_tests/mandatory/send/test553_test.exs
test/scxml_tests/mandatory/invoke/test554_test.exs` green after Phase 2, and
`mix test.regression` covering both files after Phase 3.

### Key Discoveries:

- Spec 5.9.4 explicitly makes both timings conformant ("MAY reject documents
  containing syntactically ill-formed expressions at document load time, or it
  MAY wait and place 'error.execution' in the internal event queue at runtime"),
  so this is a spec MAY being exercised, not a deviation - the same footing
  ADR-0026 records for `<script>`.
- `docs/datamodel.md:71-91` already records the per-element-class policy, states
  that "if this is ever unified, it unifies toward deferral rather than away
  from it", and names the trigger to watch for: a corpus document with an
  unparseable expression plus an `error.execution` handler. test553 and test554
  are that trigger for `namelist`.
- The `{:invalid, error}` producer/consumer shape has four precedents:
  `lib/statifier/compiler.ex:1744-1747` (`<data expr>`), `:949-954`
  (`<assign expr>`), `:976-989` (executable-content `<script>`), `:1194-1202`
  (global `<script>`).
- Every precedent types the arm **on the owning struct**, never as an arm of
  `Machine.expr()`: `lib/statifier/machine/data.ex:38`,
  `lib/statifier/machine/content/assign.ex:53`,
  `lib/statifier/machine/content/script.ex:49`. `Machine.Param` follows suit.
- `collect_invoke_param/2` is **also** used by `build_invoke_params/3`
  (`lib/statifier/compiler.ex:1584`, `:1588`), so it stays; only
  `build_invoke_namelist` stops routing through it.
- ADR-0047's `{:invalid, _reason}` on a send *target*
  (`lib/statifier/machine/content/send.ex:243`) is a different thing entirely -
  a classified target, not a captured compile error. Do not conflate them.

## What We're NOT Doing

- **Not** removing `namelist` entries from the predicator compiler. The bead
  proposes treating them as plain identifiers looked up in the datamodel; 6.2.2
  and 6.4.1 type them as location expressions and 5.9.2 governs them, so the
  entries are compiled exactly as they are today. This also avoids answering
  what a non-trivial location expression (`foo.bar`, `foo[0]`) would resolve
  against, and keeps `write_finalize_target/6`
  (`lib/statifier/interpreter.ex:789-799`) working off the compiled form it
  depends on. (Research open question 1, resolved here.)
- **Not** unifying the load-time-versus-runtime policy across all element
  classes. `cond`, `<if>`/`<elseif>` `cond`, `<foreach array>`, `<log expr>`,
  `<content expr>`, `<transition cond>`, `<donedata>` `<param>` and plain
  `<param>` on `<send>`/`<invoke>` all keep failing `compile/1` as they do
  today. No corpus file requires deferral for any of them, and the recorded
  policy in `docs/datamodel.md` is deliberately per element class. This plan
  adds one class to the deferring side and records it. (Research open question
  2, resolved here.)
- **Not** deferring `<param>` under `<send>`/`<invoke>` even though ADR-0036 and
  ADR-0031 give a `<param>`'s `expr`/`location` the same *runtime* treatment as
  a `namelist` location. The runtime rule and the load-time rule are separate
  axes, only `namelist` has a corpus test forcing the load-time half, and
  widening to `<param>` would also drag `<donedata>`'s params (ADR-0021) into
  scope. If a corpus file later forces it, the change is one call-site swap in
  `build_dparam/4`.
- **Not** adding a validator check for `namelist` entry syntax. Entry syntax is
  not a document-shape or co-occurrence constraint, and adding it there would
  reintroduce the load-time rejection this plan removes, one layer earlier.
- **Not** writing a new ADR. ADR-0026 already establishes deferral as a
  sanctioned 5.9.4 MAY, and ADR-0036/ADR-0031 already name a `namelist` location
  among the arguments whose failure discards/aborts. The decision recorded here
  extends `docs/datamodel.md`'s existing policy paragraph along the direction
  that paragraph itself states, which is following the record rather than
  overturning it. If a reviewer judges a policy change of this shape to need its
  own ADR, that is a direction-level call for a human, not a silent plan edit.
- **Not** touching `test/passing_tests.json` for anything other than adding
  test553 and test554. The file is a guarded path only for *shrinking*
  (`docs/quality-gate-changes.md`, ADR-0011); growing it needs no ledger entry.

## Implementation Approach

Three phases, split along the pipeline boundary the extension file names
(compiler/interpreter versus corpus tooling) and, within the engine, along the
`<send>` / `<invoke>` split, since the two halves fail through mechanically
different paths (a `with` short-circuit versus an `invoke_errors` accumulator).

Each engine phase carries its compile-side change **and** its runtime-side
interception together. They cannot be split further: a `{:invalid, _}` reaching
`Evaluator.evaluate/2`, which has no clause for it, is a `FunctionClauseError`,
so a phase that defers without intercepting would commit a latent crash even
though the gate would be green.

Phase 1 also introduces the shared pieces (the `Machine.Param` type arm and the
deferring builder) and exercises them, so Phase 2 consumes something already
proven rather than something merely introduced.

### The Appendix D question

No Appendix D procedure is touched. `namelist` argument evaluation lives in
clauses 6.2.2 (`<send>`), 6.4/6.4.1 (`<invoke>`), 5.9.2 (location expressions)
and 5.9.4 (errors in expressions), none of which have Appendix D pseudocode.
The Appendix D procedures nearest this work - `send`, and the invoke handling
inside `enterStates` - are not modified: `invoke_one/6`'s and
`Machine.Content.Send.execute/2`'s control flow is unchanged, only the set of
inputs that can produce their existing error branch grows. **There is therefore
no Appendix D deviation to justify in this plan.** ADR-0002 is satisfied
vacuously, and any implementer who finds themselves editing an Appendix D
procedure has left this plan's scope.

---

## Phase 1: Defer `<send>` namelist compile failures

### Overview

Add the `{:invalid, error}` arm to `Machine.Param`, add the deferring namelist
param builder, take `build_send_namelist/3` out of `build_content_node/2`'s
`with`, and intercept the shape in `Machine.Content.Send.resolve_params/2` so a
deferred entry becomes `error.execution` and discards the message per ADR-0036.

### Changes Required:

#### 1. The compiled param's type

**File**: `lib/statifier/machine/param.ex`
**Changes**: Add a local `expr` type carrying the deferral arm, following
`Machine.Data.value` / `Assign.value` / `Script.program`, and extend the
moduledoc to say when the arm appears and who consumes it. `Machine.expr()`
itself is **not** widened - no other `expr()` reader should have to handle the
arm.

While editing that moduledoc, also correct its opening sentence, which claims a
`%Param{}` is "reachable only through its owning `Statifier.Machine.Donedata.params`
list". That is already false today - `Statifier.Machine.Content.Send` and
`Statifier.Machine.Invoke` each own a `namelist` and a `params` list of
`Param.t()` (`lib/statifier/machine/invoke.ex:26-30`,
`lib/statifier/machine/content/send.ex:20-24`) - and leaving it while documenting
a `namelist`-only arm one paragraph down makes the contradiction glaring. This is
a pre-existing inaccuracy, corrected here because the plan is editing the
sentence's immediate neighbors, not as scope creep beyond that moduledoc.

```elixir
alias Statifier.Compiler.Error, as: CompilerError

@typedoc """
The compiled location/expression, or `{:invalid, error}` when a `namelist`
entry failed to compile. Only a `namelist` entry ever carries the deferral
arm: a `<param>` element's `expr`/`location` still fails
`Statifier.Compiler.compile/1` (see `docs/datamodel.md`'s per-element-class
policy). Spec 5.9.4 permits either timing; deferral is what lets a document
with an ill-formed `namelist` load at all, so 6.2.2's discard MUST and 6.4's
terminate MUST (ADR-0036, ADR-0031) get to run.
"""
@type expr :: Machine.expr() | {:invalid, CompilerError.t()}

@type t :: %__MODULE__{
        name: String.t(),
        kind: kind(),
        expr: expr(),
        ...
      }
```

#### 2. The deferring builder

**File**: `lib/statifier/compiler.ex` (beside `build_param/6`, `:1431-1454`)
**Changes**: Add `build_namelist_param/5`, which never returns an error. Leave
`build_param/6` untouched so `<param>` keeps failing `compile/1`.

```elixir
# A `namelist` entry is a location expression (6.2.2, 6.4.1, both pointing at
# 5.9.2), compiled exactly as `build_param/6` compiles one - but a compile
# failure is captured as `{:invalid, error}` on the `%MParam{}` instead of
# being returned, the same deferral shape `<data expr>` (:1744), `<assign
# expr>` (:949) and `<script>` (:976, :1194) already use. 5.9.4 permits
# either timing and `docs/datamodel.md` records this engine's leaning toward
# deferral; deferring is what lets ADR-0036's discard and ADR-0031's abort
# actually run instead of being preempted by an unloadable document
# (test553, test554). `<param>` is deliberately not deferred - see the
# per-element-class policy in docs/datamodel.md.
@spec build_namelist_param(
        name :: String.t(),
        location :: Location.t(),
        source :: String.t(),
        expr_location :: Location.t(),
        owner :: Expressions.owner_ref()
      ) :: MParam.t()
defp build_namelist_param(name, location, source, expr_location, owner) do
  expr =
    case Expressions.compile(source, owner, expr_location) do
      {:ok, expr} -> expr
      {:error, error} -> {:invalid, error}
    end

  %MParam{
    name: name,
    kind: :location,
    expr: expr,
    expr_location: expr_location,
    location: location
  }
end
```

#### 3. `<send>`'s namelist leaves the `with`

**File**: `lib/statifier/compiler.ex:1007-1037`, `:1153-1164`
**Changes**: `build_send_namelist/3` returns a bare `[MParam.t()]` (it can no
longer fail, so `collect/1` would leave a dead error branch dialyzer will
flag), and its call moves out of the `with` into a plain binding.

```elixir
@spec build_send_namelist(
        namelist :: [String.t()],
        send_node :: DSend.t(),
        owner :: Expressions.owner_ref()
      ) :: [MParam.t()]
defp build_send_namelist(namelist, send_node, owner) do
  location = send_attr_location(send_node, :namelist)
  Enum.map(namelist, &build_namelist_param(&1, send_node.location, &1, location, owner))
end
```

```elixir
defp build_content_node(c_index, %DSend{} = send_node) do
  owner = {:content, c_index}
  namelist = build_send_namelist(send_node.namelist, send_node, owner)

  with {:ok, event_expr} <- ...,
       {:ok, params} <- build_send_params(send_node.params, owner) do
    {:ok, %MSend{... namelist: namelist, ...}}
  end
end
```

Update the clause comment at `:1002-1006` in the same edit: it currently lists
"or a `namelist` entry" among the failures that stop the `with`, which stops
being true. Replace that phrase with a sentence saying a namelist entry is the
one `<send>` argument that no longer stops the `with`, and why.

#### 4. Intercept the deferred entry at send time

**File**: `lib/statifier/machine/content/send.ex:297-312`
**Changes**: `resolve_params/2`'s fold gets an `{:invalid, error}` arm ahead of
`Evaluator.evaluate/2`, matching how `Assign` and `Script` intercept the shape
before the evaluator (`Evaluator` has no clause for it).

```elixir
Enum.reduce_while(params, {:ok, []}, fn %Param{name: name, expr: expr}, {:ok, pairs} ->
  case evaluate_param(datamodel_context, expr) do
    {:ok, value} -> {:cont, {:ok, [{name, value} | pairs]}}
    {:error, reason} -> {:halt, {:error, reason}}
  end
end)

# A `namelist` entry whose location expression did not compile (5.9.4
# deferral - see `Statifier.Machine.Param`). `Statifier.Evaluator` has no
# `{:invalid, _}` clause by design, so the shape is intercepted here, exactly
# as `Machine.Content.Assign` and `Machine.Content.Script` intercept theirs.
# The `{:error, _}` return is ADR-0036's discard: the block runner converts it
# to `error.execution` and no send effect is produced.
defp evaluate_param(_datamodel_context, {:invalid, error}), do: {:error, error}
defp evaluate_param(datamodel_context, expr),
  do: Evaluator.evaluate(datamodel_context, expr)
```

Extend the existing comment above `resolve_params/2` (`:291-296`) with one
sentence naming the new arm.

#### 5. Update `Machine.Content.Send`'s moduledoc

**File**: `lib/statifier/machine/content/send.ex:20-24`
**Changes**: The moduledoc says every `namelist` entry is "compiled with"
`kind: :location`; add that an entry that fails to compile carries
`{:invalid, error}` and is discarded at execute time rather than at load time.

#### 6. Tests

**File**: `test/statifier/compiler/expressions_test.exs` (or a sibling under
`test/statifier/compiler/` if that file's fixtures do not fit)
**Changes**: A test that a `<send namelist="&quot;foo">` document compiles
`{:ok, machine}` and that the entry's `%Machine.Param{}` carries
`{:invalid, %Compiler.Error{}}`, matched by pattern rather than by asserts.
Sabotage line, e.g.
`# sabotage: build_namelist_param/5 returns the {:error, _} instead of {:invalid, _} -> red`.

**File**: `test/statifier/machine/content/send_test.exs`
**Changes**: Add a `namelist_invalid` state to the existing fixture chart
(`:41-45`) carrying `<send event="e" namelist="&quot;foo"/>`, and a test that
`ExecutableContent.execute/2` returns `{:error, _}` and produces no send
effect - the companion to the existing "namelist over an undeclared root
produces no effect at all" test at `:283`. Sabotage line, e.g.
`# sabotage: drop resolve_params/2's {:invalid, _} arm -> FunctionClauseError, red`.

**File**: `test/statifier/machine/content/send_test.exs`, the existing
`describe "execute/2 - argument failure discards the message (ADR-0036)"`
block at `:591`
**Changes**: Add the deferred-namelist case to that block alongside its
existing failing-argument cases, so the new behavior is pinned as one more
member of ADR-0036's discard set rather than as a separate concern. Sabotage
line required.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` used between edits (not a phase gate on its
      own).
- [x] Full `mix quality` is green, and `mix gate.verify` confirms the run was
      unprofiled, unscoped, not `--quick` and not `--skip`-ed.
- [x] Dialyzer, inside that gate, is green - the removed `collect/1` call and
      the narrowed `build_send_namelist/3` spec are exactly what it would flag.
- [x] `mix test --include scxml_w3 test/scxml_tests/mandatory/send/test553_test.exs`
      passes. (test554 still fails; that is Phase 2.)
- [x] `mix test.regression` still green - no ratchet entry changes in this
      phase, so any movement here is a regression.
- [x] Each new test asserting `lib/` behavior carries its one-line sabotage
      comment - this half the gate's sabotage scan really does check.

#### Manual Verification:
- [ ] The sabotage mutation each new test names was actually applied, seen red,
      and reverted, with `MIX_ENV=test mix compile --force` on both sides
      (`docs/testing.md`). This is an implementer attestation, not an automated
      criterion: `docs/testing.md:167-170` says the scan "only checks that a
      `# sabotage:` note exists above the test, never that the mutation it names
      would actually change the value under test", so no command in this repo
      can decide it.
- [ ] Spec-conformance judgment on the touched functions: 6.2.2's "If the
      evaluation of `<send>`'s arguments produces an error, the Processor MUST
      discard the message without attempting to deliver it" is what the new path
      produces, and 5.9.4's deferral MAY is what licenses the load-time change.
      Read both clauses from the local cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
      not from memory. No Appendix D procedure is touched, so there is no
      pseudocode deviation to justify.
- [ ] A `<send>` with a *well-formed* namelist still behaves identically -
      spot-check the existing `namelist`, `namelist_unbound` and
      `namelist_undeclared` cases in `send_test.exs`.
- [ ] No regressions in `<param>`-based sends, `<donedata>` params, or
      `<content expr>`: none of them should have changed shape.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Defer `<invoke>` namelist compile failures

### Overview

Stop routing `<invoke>`'s namelist entries through the `invoke_errors` sink,
so a failing entry survives instead of being dropped by `Enum.reject/2`, and
intercept the deferred shape in `Interpreter.resolve_params/2` so the
invocation aborts per ADR-0031. Also close the `auto_assign_finalize/5` gap
that a `{:invalid, _}` entry would otherwise open.

### Changes Required:

#### 1. `build_invoke_namelist` stops threading `acc`

**File**: `lib/statifier/compiler.ex:1600-1618`, call site `:1502`
**Changes**: Becomes `build_invoke_namelist/3` returning `[MParam.t()]`, built
from `build_namelist_param/5`. The `Enum.map_reduce/3`, the
`collect_invoke_param/2` hop and the `Enum.reject(&is_nil/1)` all go away -
that reject is exactly what would have silently swallowed the deferred entry
(research open question 3). `collect_invoke_param/2` itself **stays**: it is
still used by `build_invoke_params/3` (`:1584`, `:1588`).

```elixir
@spec build_invoke_namelist(
        namelist :: [String.t()],
        invoke :: DInvoke.t(),
        owner :: Expressions.owner_ref()
      ) :: [MParam.t()]
defp build_invoke_namelist(namelist, invoke, owner) do
  location = invoke_attr_location(invoke, :namelist)
  Enum.map(namelist, &build_namelist_param(&1, invoke.location, &1, location, owner))
end
```

Call site in `build_invoke/3` becomes
`namelist = build_invoke_namelist(invoke.namelist, invoke, owner)` (no `acc`
rebinding), placed so the surrounding `acc` threading order is otherwise
untouched.

Update the two comments that now misdescribe the code: `build_invoke/3`'s at
`:1470-1482` (it lists "or namelist entry" among the failures recorded onto
`acc.invoke_errors`) and the module's own `invoke_acc`/`invoke_errors` section
at `:143-157` (same phrase). Both should say a namelist entry is the one
`<invoke>` argument that defers instead of landing in `invoke_errors`.

#### 2. Intercept the deferred entry at invoke time

**File**: `lib/statifier/interpreter.ex:1434-1449`
**Changes**: The same `evaluate_param/2` interception Phase 1 adds to
`Machine.Content.Send`, with the same comment naming the deferral and ADR-0031
rather than ADR-0036. The `{:error, _}` reaches `invoke_one/6`'s `else`
(`:1414-1416`) and `abort_invocation/4` raises `error.execution` with origin
`{:invoke, state_index, invoke_index}`, unchanged.

#### 3. Keep `write_finalize_target/6`'s precondition true

**File**: `lib/statifier/interpreter.ex:735-759`
**Changes**: `write_finalize_target/6` pattern-matches
`%Param{expr: {:compiled, _compiled, source}}` and would raise
`FunctionClauseError` on a deferred entry. Narrow the existing filter in
`auto_assign_finalize/5` instead of adding a defensive clause:

```elixir
(invoke.namelist ++ invoke.params)
# A deferred `namelist` entry (`{:invalid, _}`, see `Statifier.Machine.Param`)
# is unreachable here in practice - such an entry aborts the invocation in
# `invoke_one/6` before any invocation exists to finalize - but the filter
# states the precondition `write_finalize_target/6` pattern-matches on rather
# than leaving it to a `FunctionClauseError`.
|> Enum.filter(&(&1.kind == :location and match?({:compiled, _compiled, _source}, &1.expr)))
```

Update `write_finalize_target/6`'s comment at `:764-770`, which asserts
`param.expr` for a `kind: :location` entry "is always `{:compiled, _compiled,
source}`", to name the filter as what makes that true now.

#### 4. Update `Machine.Invoke`'s moduledoc

**File**: `lib/statifier/machine/invoke.ex:26-30`
**Changes**: Same one-sentence addition Phase 1 makes to
`Machine.Content.Send`'s moduledoc.

#### 5. Tests

**File**: `test/statifier/compiler/invoke_test.exs`
**Changes**: Add an invoke with `namelist="&quot;foo"` to the existing fixture
(`:37`) or a sibling chart, and a test that the document compiles and the
entry is **present** in `inv.namelist` carrying `{:invalid, %Compiler.Error{}}`
- the presence assertion is the one that pins the removed `Enum.reject/2`.
Sabotage line, e.g.
`# sabotage: restore Enum.reject(&is_nil/1) in build_invoke_namelist/3 -> entry vanishes, red`.

**File**: `test/statifier/interpreter/invoke_pass_test.exs` - model it on the
existing test at `:348`, "a failing typeexpr raises error.execution and
produces no effect, but a sibling still does", which is the same assertion
shape one argument over
**Changes**: A test that a state carrying `<invoke namelist="&quot;foo">`
raises `error.execution` with origin `{:invoke, state_index, invoke_index}` and
produces no `Effect.Invoke`, and that a sibling invoke on the same state is
unaffected (`invoke_state/3`'s fold accumulates rather than halting,
`lib/statifier/interpreter.ex:1322-1334`). Sabotage line required.

**File**: `test/statifier/interpreter/finalize_test.exs`
**Changes**: No new test is required - the filter's false branch is unreachable
by construction (see #3). Note this explicitly in the phase's commit body
rather than writing a test that can only be made to fail by constructing a
`%Machine{}` by hand.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` used between edits.
- [ ] Full `mix quality` green, confirmed by `mix gate.verify`.
- [ ] `mix test --include scxml_w3 test/scxml_tests/mandatory/invoke/test554_test.exs`
      passes, and test553 still passes.
- [ ] `mix test.regression` still green.
- [ ] Every new `lib/`-asserting test carries its sabotage line (the half the
      gate's scan checks).

#### Manual Verification:
- [ ] The named sabotage mutations were applied, seen red, and reverted, with
      `MIX_ENV=test mix compile --force` on both sides - an implementer
      attestation for the same reason Phase 1 records it as one.
- [ ] Spec-conformance judgment on the touched functions: 6.4's "if the
      evaluation of its arguments produces an error, the SCXML Processor MUST
      terminate the processing of the element without further action", read from
      the local spec cache. Confirm no Appendix D procedure moved.
- [ ] A well-formed `<invoke namelist="a b">` still compiles to two ordered
      `kind: :location` params and still seeds a child session's datamodel
      (`test/statifier/session/invoke_start_child_test.exs`).
- [ ] `<finalize>` auto-assign still writes for a well-formed namelist
      (`test/statifier/interpreter/finalize_test.exs`), and the narrowed filter
      changed nothing there.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Record the policy and ratchet the corpus

### Overview

Update the two written records that this change makes inaccurate, add the
changelog fragment, and take the deliberate ratchet step that turns test553 and
test554 from "happens to pass" into "must always pass".

### Changes Required:

#### 1. The recorded deferral policy

**File**: `docs/datamodel.md:71-91`
**Changes**: The bolded sentence currently reads "An expression that fails to
compile is rejected at load time everywhere except `<data expr>` and `<assign
expr>`, which defer to runtime." Three things change:

- The exception list gains `<script>` (already true before this bead, per
  ADR-0026, and currently unrecorded here) and `<send>`/`<invoke>` `namelist`
  entries.
- The "trigger to watch for" paragraph gets a sentence recording that the
  trigger **fired** for `namelist` in st-vwdg - test553 and test554 are corpus
  documents with an unparseable location expression and an expected `pass` that
  depends on catching the resulting behavior - and that the response was to move
  one more element class to the deferring side, not to unify the whole policy.
  The `cond` half of the trigger is still unfired; say so, and keep test344's
  disclaimer.
- The remaining load-time-rejecting classes stay named explicitly (`cond`,
  `<log expr>`, `<content expr>`, `<foreach array>`, `<param>`), so the split
  stays readable as a list rather than as an exception to an exception.

Keep the file's existing typography and hyphen conventions.

#### 2. `compile/1`'s `@doc` contract

**File**: `lib/statifier/compiler.ex:193-198`
**Changes**: The `@doc` claims `{:error, errors}` "signals a compiler defect (an
id that fails to resolve during the numbering walk) rather than a malformed
input document". That was already inaccurate before this bead and stays
inaccurate after it, for the classes that still reject at load time: an
unparseable `cond` or `<log expr>` is a malformed input document producing
exactly that tuple. Correct the sentence to name both sources - a compiler
defect **and** an expression-compile failure in a non-deferring element class -
and point at `docs/datamodel.md`'s policy paragraph for which classes those are.
Do not weaken the caller guidance beyond what is true. (Research open question
4, resolved here: it is corrected as part of st-vwdg, in the phase where the
policy paragraph it points at is also written.)

#### 3. Changelog fragment

**File**: `changelog.d/st-vwdg.md`
**Changes**: One fragment covering both halves. This is user-visible: a document
that previously failed `Statifier.compile/1` now loads and raises
`error.execution` at evaluation time. Follow `changelog.d/README.md`'s format
and the "while v2 is unreleased" guidance in that file.

#### 4. The ratchet

**Files**: `test/passing_tests.json` (via the mix task, not by hand)
**Changes**: Confirm both tests pass, then ratchet them in:

```bash
mix test --include scxml_w3 \
  test/scxml_tests/mandatory/send/test553_test.exs \
  test/scxml_tests/mandatory/invoke/test554_test.exs

mix test.baseline add \
  test/scxml_tests/mandatory/send/test553_test.exs \
  test/scxml_tests/mandatory/invoke/test554_test.exs

mix test.regression
```

`mix test.baseline add` is all-or-nothing and verifies each file before adding
it, so a red file cannot enter the registry (`docs/testing.md:220-236`). This is
a deliberate step, not an automatic one - nothing else in the gate will add
them. Growing `test/passing_tests.json` is not a guarded change; only shrinking
it is (`docs/quality-gate-changes.md`, ADR-0011), so **no ledger entry is needed
or should be written**. (Research open question 5, resolved here.)

Do not regenerate the corpus (`mise run corpus`) in this phase: neither fixture
changes, and neither appears in `tools/corpus/scxml_w3/exclusions.exs` or
`sub_documents.exs`.

### Success Criteria:

#### Automated Verification:
- [ ] `mix test --include scxml_w3` on both files passes **before**
      `mix test.baseline add` is run.
- [ ] `test/passing_tests.json`'s `w3c_tests` list grows by exactly two entries,
      naming those two files, with no other list touched.
- [ ] `mix test.regression` green and now running both files - confirm by the
      task's own per-corpus W3C count rising by two.
- [ ] Full `mix quality` green, confirmed by `mix gate.verify`; the
      `Regression ratchet` stage in particular must be a real pass, not a skip.
- [ ] `mix quality --format json --report -` if a downstream agent needs to
      route on the stage results.
- [ ] `git diff` for this phase touches only `docs/datamodel.md`,
      `lib/statifier/compiler.ex` (the `@doc` only), `changelog.d/st-vwdg.md`
      and `test/passing_tests.json`.

#### Manual Verification:
- [ ] Spec-conformance judgment on the `lib/` change: the corrected `compile/1`
      `@doc` describes what the function actually returns for every class named
      in the updated `docs/datamodel.md` paragraph, with 5.9.4 cited as the
      authority for the split.
- [ ] The `docs/datamodel.md` edit reads as an extension of the recorded
      leaning ("if this is ever unified, it unifies toward deferral"), not as a
      quiet reversal, and a reader who only reads that paragraph can still tell
      which element classes reject at load time.
- [ ] The changelog fragment is written for someone who only calls the public
      API and can tell the difference.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before finishing. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement automatically
(via `/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

- Neither fixture is regenerated: `mise run corpus` is not run by this plan.
  Both files are ordinary `mandatory/` W3C cases carrying
  `datamodel="predicator"`, absent from both corpus filters
  (`tools/corpus/scxml_w3/exclusions.exs`, `sub_documents.exs`), and are emitted
  normally today.
- Both are currently *untracked failing* tests, not suppressed ones: nothing in
  `test/passing_tests.json`, no expected-failure list, no `@tag :skip`. So the
  gate is green today **despite** them, and stays green after Phase 1 and Phase 2
  whether or not they pass - which is exactly why the explicit per-file
  `mix test --include scxml_w3` runs are in those phases' automated criteria
  rather than being left to the gate.
- Phase 1 flips test553 only; Phase 2 flips test554. If Phase 1's run shows
  test554 also passing, that means the `<invoke>` half was pulled forward and the
  phase boundary was crossed - re-split rather than ratcheting early.
- Ratcheting happens once, in Phase 3, after both halves are committed. Adding
  entries never needs a `docs/quality-gate-changes.md` entry; removing or
  shrinking would.

## Testing Strategy

### Unit Tests:

- **Compiler, `<send>`** - a malformed namelist entry yields `{:ok, machine}`
  with `{:invalid, %Compiler.Error{}}` on the entry's `%Machine.Param{}`, and a
  well-formed sibling entry in the same attribute still compiles to
  `{:compiled, _, _}`. The mixed case is the interesting one: the deferral must
  be per entry, not per attribute.
- **Compiler, `<invoke>`** - same, plus the presence assertion that pins the
  removed `Enum.reject(&is_nil/1)`, plus `compile/1` returning `{:ok, _}` rather
  than accumulating into `invoke_errors`.
- **`Machine.Content.Send.execute/2`** - a deferred entry returns `{:error, _}`
  and produces no send effect; the error carries the captured
  `%Compiler.Error{}` so the diagnostic survives to the event's `data`.
- **`Interpreter` invoke** - a deferred entry raises `error.execution` with
  origin `{:invoke, state_index, invoke_index}`, produces no `Effect.Invoke`,
  and leaves a sibling invoke on the same state unaffected.
- **End to end** - one chart per element mirroring test553's and test554's
  shape, so the behavior is pinned by an internal test that runs on every
  `mix test`, not only by a `:scxml_w3`-tagged corpus file excluded by default.
- Every one of these carries a one-line sabotage comment naming the mutation,
  run red and reverted with `MIX_ENV=test mix compile --force` on both sides
  (`docs/testing.md`).

### Manual Testing Steps:

1. Read 5.9.4, 5.9.2, 6.2.2 and 6.4 from the local spec cache and confirm the
   quoted MUST/MAY text matches what the implementation does. Do not rely on
   recalled spec text.
2. `mix test --include scxml_w3 --include scion` in full, once, after Phase 2,
   and compare the failure list against the st-cmq.9 red-to-bead ledger: the
   only movement should be test553 and test554 going green. Anything else moving
   is a regression this plan did not intend.
3. Load a document with a malformed `namelist` through the public
   `Statifier.compile/1` and confirm it returns `{:ok, machine}` - the
   user-visible change the changelog fragment describes.
4. Confirm a malformed `cond` still fails `Statifier.compile/1`, so the
   per-element-class split is genuinely still a split.

## References

- Source document:
  `docs/research/260818-st-vwdg-namelist-compile-failure-deferral.md`
- Related ADRs:
  `docs/adr/0036-send-argument-failure-discards-the-message.md`,
  `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md`,
  `docs/adr/0026-script-as-predicator-statement-programs.md` (deferral as a
  sanctioned 5.9.4 MAY),
  `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`
  (a different `{:invalid, _}` usage, not to be conflated),
  `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0021-donedata-content-expr-failure-yields-no-data.md`,
  `docs/adr/0033-validator-warning-tier.md`
- Recorded policy: `docs/datamodel.md:71-91`
- Similar implementation: `lib/statifier/compiler.ex:949-954` and
  `lib/statifier/machine/content/assign.ex:118` (the `<assign expr>` deferral,
  producer and consumer); `lib/statifier/compiler.ex:976-989` and
  `lib/statifier/machine/content/script.ex:68` (the `<script>` pair)
- Decision precedents:
  `docs/plans/260814-st-af3.17-script-statement-bodies.md:163-178` ("Decision
  1"), `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`
  ("Decision 2"),
  `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md` ("Decision 6")
- Ratchet protocol: `docs/testing.md:220-236`
- Bead: st-vwdg

## Decisions Recorded By This Plan

Written here rather than in a new ADR, following the "Decision N" convention
`<data expr>`, `<assign expr>` and `<script>` each used before their shapes were
promoted.

**Decision 1: a `namelist` entry that fails to compile defers to runtime.** The
compile error is captured as `{:invalid, %Compiler.Error{}}` on the entry's
`%Machine.Param{}` and short-circuited at argument-resolution time into the
`error.execution` ADR-0036 and ADR-0031 already specify. Authority: 5.9.4's
explicit MAY, plus `docs/datamodel.md`'s recorded leaning toward deferral when
the split moves. Scope: `namelist` entries on `<send>` and `<invoke>` only.

**Decision 2: the entries stay compiled as location expressions.** 6.2.2 and
6.4.1 type `namelist` as a list of location expressions governed by 5.9.2, so
the bead's proposed "treat them as plain identifiers" reshaping is declined.
This also preserves `write_finalize_target/6`'s dependence on the compiled form.

**Decision 3: `<param>` is not deferred.** Only `namelist` moves. The runtime
rule (ADR-0036/ADR-0031 treat a `<param>` and a `namelist` entry alike) and the
load-time rule are separate axes, and only `namelist` has corpus evidence
forcing the load-time half.

## Assumptions and Open Items

No human was available while this plan was written, so the following were
decided rather than asked. Each is recorded so a reviewer can overturn it
cheaply.

1. **Assumption**: extending `docs/datamodel.md`'s policy paragraph is a record
   update, not a direction decision needing a new ADR, because that paragraph
   already states the direction ("if this is ever unified, it unifies toward
   deferral") and names the trigger this bead fires. If a reviewer disagrees,
   Phase 3's `docs/datamodel.md` edit becomes an ADR and the code phases are
   unaffected.
2. **Assumption**: the deferral is scoped to `namelist` rather than applied to
   every `<send>`/`<invoke>` argument, on the evidence rule that only `namelist`
   has a corpus file forcing it. Widening later is a call-site swap in
   `build_dparam/4`, so nothing here is hard to reverse.
3. **Assumption**: the unreachable `{:invalid, _}` branch in
   `auto_assign_finalize/5` is handled by narrowing the existing filter rather
   than by adding a defensive `write_finalize_target/6` clause, so no uncoverable
   line is introduced under the project's 100% Doctor and coveralls thresholds.
   If the implementer finds a reachable path, that is a real bug and the clause
   should be added with a test instead.
4. **Open item, deliberately out of scope**: the load-time-versus-runtime split
   remains per element class rather than processor-wide, which 5.9.4 frames as a
   single processor-wide policy. This plan moves one class and records it; the
   full unification stays unbid until a corpus file forces the `cond` half.
5. **Resolved during planning**: the two existing test homes were located and
   are named in the phases -
   `test/statifier/machine/content/send_test.exs:591` (ADR-0036's discard
   describe block) and `test/statifier/interpreter/invoke_pass_test.exs:348`
   (the failing-`typeexpr` abort test). Extend them; do not create new files
   for these cases.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The sabotage mutation each new test names was actually applied, seen red,
      and reverted, with `MIX_ENV=test mix compile --force` on both sides
      (`docs/testing.md`). This is an implementer attestation, not an automated
      criterion: `docs/testing.md:167-170` says the scan "only checks that a
      `# sabotage:` note exists above the test, never that the mutation it names
      would actually change the value under test", so no command in this repo
      can decide it.
- [ ] Spec-conformance judgment on the touched functions: 6.2.2's "If the
      evaluation of `<send>`'s arguments produces an error, the Processor MUST
      discard the message without attempting to deliver it" is what the new path
      produces, and 5.9.4's deferral MAY is what licenses the load-time change.
      Read both clauses from the local cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
      not from memory. No Appendix D procedure is touched, so there is no
      pseudocode deviation to justify.
- [ ] A `<send>` with a *well-formed* namelist still behaves identically -
      spot-check the existing `namelist`, `namelist_unbound` and
      `namelist_undeclared` cases in `send_test.exs`.
- [ ] No regressions in `<param>`-based sends, `<donedata>` params, or
      `<content expr>`: none of them should have changed shape.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
