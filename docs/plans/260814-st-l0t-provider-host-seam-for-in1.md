# Provider/host seam for `In/1` Implementation Plan

## Overview

Convert `Statifier.Evaluator`'s `In/1` from a captured closure into a
`Predicator.FunctionProvider` reading `context.host`, then take the win that
conversion unlocks: the functions map stops being rebuilt on every context
build, and the moving part of a build - the configuration - arrives through
`Predicator.Context.put_host/2` instead. Finally, re-answer the storage
question the `Statifier.Evaluator` moduledoc settles today, in an ADR, on the
new grounds.

Beads issue: `st-l0t`. Source research:
`docs/research/260814-st-l0t-provider-host-seam-for-in1.md`.

## Current State Analysis

`Statifier.Evaluator.context/1` (`lib/statifier/evaluator.ex:119-125`) is the
sole constructor of a `%Predicator.Context{}` over live machine data:

```elixir
Predicator.Context.new(undefine_nils(machine_state.datamodel),
  functions: %{"In" => {1, in_function(machine_state)}},
  on_unbound: :error
)
```

`in_function/1` (`:373-382`) closes over `machine_state.machine` and
`machine_state.configuration` and ignores its `%Predicator.Context{}` argument
entirely. Because the configuration is captured, the *whole* context - the
functions map included - has to be rebuilt whenever the configuration moves.

Eight call sites reach `context/1`; the research doc's section 3 table maps
each one, how often it fires, and what has moved since the previous build.
After ADR-0028, `<assign>`, `<foreach>` and `<script>` no longer rebuild
inside a block, so the surviving builds are: one per executable-content block
(`lib/statifier/interpreter/content.ex:144`), one per selection round
(`lib/statifier/interpreter/selection.ex:332` and `:364`), one per `<final>`
with `<donedata>` (`lib/statifier/interpreter/exit_entry.ex:959,992`), one per
machine instantiation and one per late-bound state
(`lib/statifier/interpreter/datamodel.ex:133,292`), plus the
not-corpus-reachable `condition_match/2` (`selection.ex:285`).

Three measured facts bound the design (research doc section 2, and
`bench/results/260814-context-build.md`):

- `Context.put_host/2` costs 0.0478 us / 0.0859 KB against
  `Evaluator.context/1`'s 2.54 us / 10.92 KB - ~53x faster, ~127x lighter.
- `Context.resolve_functions/1` costs the same with a provider (1.46 us /
  5.80 KB) as with today's inline closure (1.39 us / 5.59 KB). **A provider
  swap by itself moves no benchmark number.**
- That fixed resolution term is 56.6% of one build at the `:corpus` size point
  (`T_fixed / T_full`, ADR-0028's Modifier C), and context construction is
  62.0% of a macrostep's wall time and 67.1% of its allocation.

So the seam's value is not that a provider resolves faster. It is that a
provider-built functions map contains no captured configuration, which makes
that map **static** - identical for every context this library ever builds -
and makes the configuration a value that can be set separately, per site, with
`put_host/2`.

`Predicator.Context.resolve_functions/1` is public
(`deps/predicator/lib/predicator/context.ex:158-167`), and the map it returns
under a provider is entirely `{module, atom}` pairs - 25 entries, builtins
included, verified by the research doc's probe. A term with no `function()`
value in it is escapable into a module attribute, so the static half of a
context can be resolved once at compile time and never again at runtime.

## Desired End State

`Statifier.Evaluator.context/1` builds a context by taking a compile-time
constant base context, calling `Predicator.Context.put_host/2` with this
machine_state's `{machine, configuration}`, and binding each datamodel root
into it with the existing `Evaluator.bind/3`. `Predicator.Context.new/2` is
never called on a hot path, `Predicator.Context.resolve_functions/1` never
runs at runtime, and `In/1` is a two-arity function on
`Statifier.Evaluator.Functions` named by atom.

Verification:

- `mix quality` green, full profile.
- `mix test --include scion --include scxml_w3` at exactly the counts ADR-0028
  Phase 4 recorded: **1661 tests, 107 failures**; `mix test.regression` at
  **1522/0**.
- `bench/results/260814-st-l0t-provider-host-seam.md` holds a before/after
  table for `bench/macrostep.exs`'s four document families, showing the
  per-block and per-selection-round build cost down and the measured macrostep
  down with it.
- `grep -c "in_function" lib/` returns nothing; `Predicator.Context.new/2` no
  longer appears in `lib/statifier/evaluator.ex`.
- ADR-0029 exists and is accepted, and the moduledoc section formerly titled
  "Why the built context is not a `MachineState` field" states the two grounds
  as they now stand.

### Key Discoveries:

- `Predicator.FunctionProvider` lives at
  `deps/predicator/lib/predicator/functions/provider.ex:1-52`, not the path
  the bead's description implies; the bead was written against predicator
  5.0.0's layout. Pinned version is 7.0.0.
- A provider entry receives the full `%Predicator.Context{}`, so `host`
  reaches it: `deps/predicator/lib/predicator/evaluator.ex:1289-1325` builds
  the context at call time from the evaluator's live state and dispatches
  `apply(module, fun_atom, [args, context])`.
- `Predicator.Context.new/2` is `data: normalize_value(data)` plus
  `resolve_functions(opts)` plus `on_unbound` validation plus a verbatim
  `host` (`context.ex:128-136`). `bind/3` is
  `Map.put(data, name, normalize_value(value))` (`context.ex:240-243`). For a
  map whose top-level keys are all binaries, folding `bind/3` over the roots
  produces exactly the same `data` as `new/2` would - so the fold is a
  faithful replacement, not an approximation.
- `resolve_functions/1` validates every provider module with
  `Code.ensure_loaded?/1` and `function_exported?/3` on **every** call
  (`context.ex:188-207`). This is the term `px-rnc` asks predicator to
  memoize. Hoisting it to compile time here is the statifier-side half and
  does not pre-empt the upstream decision (ADR-0025 rule 1: predicator owns
  the shape of its own memoization).
- **The Phase 2 construction was verified against the vendored predicator
  before this plan was written**, by a throwaway `mix run` probe (not
  committed): a `%Predicator.Context{}` built by `Context.new(%{}, functions:
  %{"In" => {1, {__MODULE__, :in_state}}}, on_unbound: :error)` escapes into a
  module attribute without complaint; the resolved map holds 25 entries and
  zero `function()` values; `base |> put_host/2 |> fold bind/3` produces
  `data` and `functions` **equal** (`==`) to what `Context.new/2` produces for
  the same inputs; and `In('s1')`/`In('nope')` answer `{:ok, true}`/
  `{:ok, false}` through `host`. Phase 2's equivalence test is therefore
  expected to pass on the first run - if it does not, something changed in
  predicator and the phase should stop rather than adapt.
- `Machine.index/2` is `Map.fetch(id_to_index, id)`
  (`lib/statifier/machine.ex:313`) - the ADR-0005 interning seam.
- ADR-0012 constraint 1 (`docs/observability.md:26-49`) is about
  `%MachineState{}` being a resumable position. Nothing in this plan is stored
  on `%MachineState{}`, so the constraint is untouched, the same way ADR-0028
  left it untouched.
- ADR-0028 (`docs/adr/0028-...:140-149`) names widening the threaded interval
  *across* blocks as future work gated on the two moduledoc grounds. This plan
  re-answers those grounds and deliberately still does not widen; see "What
  We're NOT Doing".
- `test/statifier/evaluator_test.exs:165-181` ("the built context is a
  snapshot") is the test most tightly coupled to the closure mechanism. A
  provider reading `host` reproduces it: a context built with one host answers
  against that host until `put_host/2` replaces it.
- `bench/` is outside every gate stage by construction (`bench/README.md`), so
  a `bench/` edit needs no ledger entry and cannot go red.

## What We're NOT Doing

- **Not storing a context on `%MachineState{}`, and not widening the threaded
  interval across blocks or microsteps.** This is the plan's largest
  deliberate omission and Phase 4's ADR records the reasoning: ground 1
  dissolves, but ground 2 converts from an impossibility into an
  exhaustiveness obligation over seven datamodel write sites, two of which
  (`MachineState.put_event/2` at `machine_state.ex:346` and the
  `Map.put_new(id, nil)` `<data>` seed at
  `lib/statifier/interpreter/datamodel.ex:146`) bind into no context today.
  Meanwhile the majority of what a stored context would have saved - the
  56.6% fixed resolution term - is obtainable with no storage at all, which is
  what Phase 2 does. The residue is worth a follow-up bead, not this one.
- **Not adding a `bench/` document family that evaluates `In()`.** See the
  open-question resolution below: the acceptance criterion is measurable
  without one, because this plan reduces build *cost*, which every existing
  document already measures.
- **Not touching `undefine_nils/1`'s genuine-`null`-versus-unbound gap.**
  `docs/research/260812-st-unt-*` and `260812-st-af3.3-*` already record it as
  latent; a provider rewrite does not reach it.
- **Not filing or acting on `px-rnc`.** Its memoization would make
  `resolve_functions/1` cheap upstream and weaken the case for hoisting it
  here, but Phase 2's hoist is compile-time and would simply become redundant
  rather than wrong. Per ADR-0025 the shape is predicator's call. The
  `mirrors:` note on `st-l0t` was refreshed 2026-08-14 and is re-read before
  Phase 4 writes the ADR.
- **Not changing any Appendix D function's signature.** `Statifier.Evaluator`
  is not an Appendix D procedure, and no interpreter port is edited by this
  plan, so there is no Appendix D deviation to justify (ADR-0002).

## Implementation Approach

Four phases, each independently committable and gate-verifiable:

1. **Capture the baseline, then swap the mechanism.** The provider swap is
   behavior-preserving and measurably neutral, which is exactly why the
   baseline has to be captured on this machine before it lands. Landing the
   swap on its own keeps the diff that changes *semantics* separate from the
   diff that changes *cost*.
2. **Hoist the static half.** With no closure left, the functions map is a
   compile-time constant; `context/1` becomes constant + `put_host/2` +
   per-root `bind/3`. This is where every measurable win lives.
3. **Measure and record.** Re-run both benchmark scripts, repair
   `bench/macrostep.exs`'s stale derivation constants, write the results doc.
4. **Decide and document.** ADR-0029 plus the moduledoc and `docs/datamodel.md`
   rewrites, citing Phase 3's numbers the way ADR-0028 cited its own.

### Resolved open questions

The research doc recorded five open questions and no human was available to
answer them. Each is resolved here, in the plan, rather than left for the
implementer.

1. **How wide should `host` be?** `{machine, configuration}`, the literal
   transcription. The narrower `{id_to_index, configuration}` exists to reduce
   duplication in a *stored* context, and this plan stores nothing - a
   stack-local context holding a second reference to an immutable
   `%Statifier.Machine{}` costs one word on the BEAM. Keeping the whole
   machine also keeps the provider reading through `Machine.index/2`, the
   public ADR-0005 seam, instead of reaching into the `id_to_index` field.
   Narrowing stays available and is a one-line change if a stored context ever
   lands; ADR-0029 records that.
2. **Does "per-selection-round builds reduced" need a new `bench/` document
   family?** No. The criterion is read as **build cost**, not build count. The
   research's caveat - that no benchmark document evaluates `In()` - bites
   only for a change whose effect is confined to `In()` evaluation or to
   eliminating a specific round's build. Phase 2 makes *every* build cheaper
   by roughly the fixed-term share, so the reduction shows up in the
   `measured macrostep` line of all four existing document families, and in
   `bench/context_build.exs`'s `T_full` scenario directly. Adding a document
   family is therefore not needed, and the `In()`-evaluating family stays
   unbuilt rather than being built for a number it would not change.

   **This reading is a load-bearing interpretive call and is escalated, not
   buried.** The research doc's own section 3 calls sites 5 and 6 - the
   selection-round builds - "the clean candidates" for becoming
   build-once-plus-refresh, which is a *count* reduction and is exactly the
   storage move this plan declines. Under this plan the number of builds at
   those sites is unchanged; only their cost falls. So the reading is stated
   in three places on purpose: here, in Phase 3's results document, and - the
   one that matters for merge - in the Phase 3 commit body and the pull
   request description, where the human closing `st-l0t` has to affirm it
   rather than discover it. If that human reads the criterion as build count
   instead, this plan has not met it, and the honest outcome is a follow-up
   bead for the widening rather than a re-argument of the reading.
3. **ADR or moduledoc rewrite for ground 2's restatement?** Both, and the ADR
   is the load-bearing half (Phase 4). ADR-0028 explicitly deferred this
   decision and named the two grounds it was gated on; re-answering them is a
   direction-level decision with a "no, and here is what changed" outcome,
   which is precisely what an ADR is for. A moduledoc-only rewrite would leave
   the next reader unable to tell whether the question was decided or drifted.
4. **Is the duplication a stored context introduces a constraint-1 concern in
   its own right?** Recorded in ADR-0029 as a third ground against storage,
   distinct from both existing ones: two fields that must agree and can
   silently disagree is a different failure mode from a closure, and
   `lib/statifier/machine_state.ex:169-180` already documents a related sharp
   edge. It is not decisive on its own - it is decided alongside grounds 1 and
   2, and it is moot for this plan because nothing is stored.
5. **`px-rnc` weakening the case.** Noted in ADR-0029 and in the moduledoc, not
   blocked on. See "What We're NOT Doing".

---

## Phase 1: Baseline capture and the provider seam

### Overview

Record the before-numbers on this machine, then replace `In/1`'s closure with
a `Predicator.FunctionProvider`. Behavior-preserving and expected to move no
benchmark number - confirming that expectation is part of the phase.

### Changes Required:

#### 1. Baseline benchmark capture

**File**: `bench/results/260814-st-l0t-provider-host-seam.md` (new)
**Changes**: Run `mix run bench/macrostep.exs` and
`mix run bench/context_build.exs` on the merge-base tree, before any `lib/`
edit in this phase, and record the `measured macrostep` figure for each
document family plus `T_full`/`T_fixed`/`T_bind` at every size point, under a
"Before (baseline, this machine)" heading. Record machine, Elixir/Erlang, and
benchee versions the way `bench/results/260814-macrostep.md` does. The Phase 4
verification table in `bench/results/260814-macrostep.md` is the historical
before-set; this capture exists so the comparison is same-machine rather than
same-machine-class.

Do not report the script's derived `S_time`/`S_mem` figures: they are already
declared dead in `bench/results/260814-macrostep.md`, and Phase 3 repairs the
constants that make them so.

#### 2. The provider module

**File**: `lib/statifier/evaluator/functions.ex` (new)
**Changes**: A `Predicator.FunctionProvider` implementation carrying `In/1`.
`@moduledoc`, `@doc` and `@spec` on every public function are required -
`.doctor.exs` holds 100% on every axis.

```elixir
defmodule Statifier.Evaluator.Functions do
  @behaviour Predicator.FunctionProvider

  @functions %{"In" => {1, :in_state}}

  @impl Predicator.FunctionProvider
  @spec functions() :: %{String.t() => {non_neg_integer(), atom()}}
  def functions, do: @functions

  @spec in_state(args :: list(), context :: Predicator.Context.t()) :: {:ok, boolean()}
  def in_state([state_id], %Predicator.Context{host: {machine, configuration}}) do
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
```

The `:error` -> `{:ok, false}` comment on `in_function/1`
(`evaluator.ex:366-372`) moves here verbatim: it is the reason this leaf does
not produce an `{:error, _}`, and it is still the reason.

#### 3. `context/1` passes a provider and a host

**File**: `lib/statifier/evaluator.ex`
**Changes**: `context/1` swaps `functions:` for `providers:` and `host:`;
`in_function/1` is deleted.

```elixir
def context(%MachineState{} = machine_state) do
  Predicator.Context.new(undefine_nils(machine_state.datamodel),
    providers: [Statifier.Evaluator.Functions],
    host: {machine_state.machine, machine_state.configuration},
    on_unbound: :error
  )
end
```

`context/1`'s own `@doc` currently describes the snapshot property in terms of
"`In/1`'s closure captures" (`evaluator.ex:112-117`); restate it in terms of
the host term. The same closure language appears in `bind/3`'s `@doc`
(`:170-174`) and `run_program/2`'s (`:307-311`) - both say `functions` carries
`In/1`'s captured configuration over. Under the seam it is `host` that carries
over, and `bind/3`/`Predicator.execute/3` both preserve it unchanged, so the
*conclusion* of each paragraph is unchanged and only the mechanism named in it
moves. Do not rewrite the "Why the built context is not a `MachineState`
field" section in this phase; that is Phase 4's, and splitting it keeps the
mechanical diff readable.

#### 4. Tests

**File**: `test/statifier/evaluator_test.exs`
**Changes**: The existing `In/1` tests (`:133-136`, `:142-145`, `:153-156`)
and the snapshot test (`:165-181`) must pass unedited - if any needs editing,
stop and report, because that is a behavior change rather than a mechanism
change. Add:

- a test that a built context contains no `function()` value anywhere: every
  entry in `context.functions` matches `{_arity, {module, atom}}`. This is
  ground 1's dissolution made mechanical, and it is what Phase 4's ADR cites.
- a test that `context.host` is `{machine, configuration}` and that
  `Predicator.Context.put_host/2` with a different configuration changes
  `In/1`'s answer without rebuilding.

Every new test carries the sabotage line CLAUDE.md requires - break the code
it covers, confirm red, revert, and write the one-line note above the test
(`# sabotage: in_state/2 ignores host's configuration -> red`).

**File**: `test/statifier/machine/content/assign_test.exs`
**Changes**: The sabotage comment at `:267-271` describes the pre-ADR-0028
mechanism (`Evaluator.context(ms)`) while `assign.ex:93-94` binds. The
assertion is current; the prose is stale. Fix the prose only - do not touch
the assertion. (Incidental finding from the research doc, folded in here
because it is prose about the same mechanism this phase moves.)

Adversarial review flagged this as a second file's prose riding along in a
phase whose subject is `lib/statifier/evaluator.ex`, and suggested dropping it
or moving it to Phase 4. Kept here deliberately: the comment is wrong *about
the mechanism this phase replaces*, a reader hitting it mid-phase would be
misled by it, and deferring a one-line comment fix to a phase three commits
later is how a stale comment survives a whole branch. It is two lines of
prose in a test file, and it changes no assertion.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (never as the phase gate)
- [x] Full `mix quality` green, verified through `mix gate.verify`
- [x] `mix test.regression` at 1522/0
- [x] `mix test --include scion --include scxml_w3` at exactly 1661 tests, 107 failures
- [x] `grep -rn "in_function" lib/` returns nothing
- [x] `bench/results/260814-st-l0t-provider-host-seam.md` exists with a Before section
- [x] `mix run bench/context_build.exs` completes after the swap

#### Manual Verification:
- [ ] The post-swap `T_full` reproduces the Before `T_full` **within noise**,
      confirming the research's central correction that a provider swap by
      itself moves no number. This is a judgment about benchee's variance, not
      a threshold a script can decide, so it is deliberately not an automated
      criterion - if the two differ by more than noise, stop and report rather
      than proceeding to Phase 2 on an unexplained delta.
- [ ] The `In(stateId)` semantics still match spec 5.10: true exactly when
      `stateId` names a state in the current configuration, and an undeclared
      id answers "not active" rather than raising. Read the clause locally
      from the spec cache, do not recall it.
- [ ] No Appendix D procedure was edited, so no ADR-0002 deviation comment is
      owed (ADR-0002 applies to the interpreter ports; `Statifier.Evaluator`
      is not one).
- [ ] The moved `:error` -> `{:ok, false}` comment still reads as the reason
      for the answer, not as a description of the code below it (ADR-0018).

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving on. In looped (`--loop`)
execution, the Automated Verification list gates advancement via
`/wurk:commit --auto`, and Manual Verification items are deferred and
surfaced once at the end.

---

## Phase 2: Resolve the functions map once, refresh the host per site

### Overview

With no closure in `functions`, the resolved map is a constant. Hoist it to a
compile-time base context and rebuild `context/1` as
`base |> put_host/2 |> bind each root`. `Predicator.Context.new/2` and
`Predicator.Context.resolve_functions/1` leave the runtime path entirely.

### Changes Required:

#### 1. The compile-time base context

**File**: `lib/statifier/evaluator/functions.ex`
**Changes**: Add a `base_context/0` returning a module attribute built at
compile time.

```elixir
@base_context Predicator.Context.new(%{},
                builtins: true,
                functions: %{"In" => {1, {__MODULE__, :in_state}}},
                on_unbound: :error
              )

@doc """
The fixed half of every context this library builds ...
"""
@spec base_context() :: Predicator.Context.t()
def base_context, do: @base_context
```

Two details the implementer must not paper over:

- The entry is written as `{1, {__MODULE__, :in_state}}` through the
  `:functions` option rather than as `providers: [__MODULE__]`, because
  `resolve_functions/1` would call `Code.ensure_loaded?/1` on the module
  currently being compiled. The `:functions` option merges the entry
  unvalidated (`context.ex:158-167`), and predicator's dispatch treats a
  `{module, atom}` pair identically whichever option delivered it
  (`deps/predicator/lib/predicator/evaluator.ex:1319-1321`). `functions/0`
  still exists and still satisfies the behaviour - it is the declaration the
  bead's acceptance criterion names - and a test asserts the two agree, so the
  hand-shaped entry cannot drift from it.
- A module attribute must be escapable. A `%Predicator.Context{}` holding only
  `{module, atom}` pairs is; one holding a `function()` is not, and would fail
  at compile time. That failure mode is the point: it is ground 1's guarantee
  enforced by the compiler rather than by review.

If the attribute cannot be escaped for a reason not anticipated here, the
fallback is a lazily-computed `:persistent_term` cache keyed by this module -
same constant, same public shape, one process-global read instead of a
literal. Take the fallback only on a demonstrated compile failure, and say so
in the commit body.

#### 2. `context/1` becomes host-refresh plus per-root bind

**File**: `lib/statifier/evaluator.ex`

```elixir
def context(%MachineState{machine: machine, configuration: configuration} = machine_state) do
  Statifier.Evaluator.Functions.base_context()
  |> Predicator.Context.put_host({machine, configuration})
  |> bind_roots(machine_state.datamodel)
end

@spec bind_roots(context :: Predicator.Context.t(), datamodel :: map()) ::
        Predicator.Context.t()
defp bind_roots(context, datamodel) do
  Enum.reduce(datamodel, context, fn {root, value}, acc -> bind(acc, root, value) end)
end
```

`bind/3` is the existing public helper: it applies `undefine_nils/1` to the
value and hands it to `Predicator.Context.bind/3`, which applies
`normalize_value/1`. Folding that over the roots produces exactly the `data`
`new/2` produced, because `new/2` is `normalize_value(whole_map)` and
`normalize_value` on a map recurses per entry. `undefine_nils/1` keeps its
existing call from `bind/3` and is no longer called on the whole map.

**The one precondition**: every top-level key in `machine_state.datamodel`
must be a binary, since `Predicator.Context.bind/3` guards `is_binary(name)`
where `new/2` would have stringified an atom key. The implementer verifies
this against all seven writers the research doc's section 3 table names -
`machine_state.ex:276` (the seed, from `SystemVariables.initial/2` and
`<data id>`), `machine_state.ex:346` (`"_event"`),
`interpreter/datamodel.ex:146` and `:201` (`<data id>`),
`evaluator.ex:334` (roots out of a predicator-normalized context, already
binary), `content/assign.ex:86` (a declared `location` root), and
`content/foreach.ex:302` (declared `item`/`index`) - and records the finding
in the commit body. A non-binary root would now raise a `FunctionClauseError`
where it used to be silently stringified; that is a louder failure for a case
no writer can produce, and it is worth a note in `context/1`'s `@doc`.

#### 3. The refresh seam, made public

**File**: `lib/statifier/evaluator.ex`
**Changes**: A public `put_configuration/2` over `Predicator.Context.put_host/2`,
so a caller that ever does hold a context across a configuration change has a
named, documented way to refresh it without touching predicator directly - the
same reason `bind/3` is public rather than inlined.

```elixir
@spec put_configuration(
        context :: Predicator.Context.t(),
        machine_state :: MachineState.t()
      ) :: Predicator.Context.t()
def put_configuration(%Predicator.Context{} = context, %MachineState{} = machine_state)
```

Its `@doc` states plainly that no `lib/` caller holds a context across a
configuration change today, that this is the seam such a caller would use, and
that `data` staleness is *not* addressed by it - which is ground 2 in one
paragraph, at the place someone reaching for the function will read it.

#### 4. Tests

**File**: `test/statifier/evaluator_test.exs` and
`test/statifier/evaluator/functions_test.exs` (new)

- Equivalence: for a representative datamodel - nested maps, lists, a `nil`
  root, a nested `nil`, a non-string scalar, `_event` - the context `context/1`
  now builds has `data`, `on_unbound` and `functions` identical to what
  `Predicator.Context.new(undefine_nils(datamodel), providers: [...],
  host: ..., on_unbound: :error)` builds. This is the whole safety argument for
  bypassing `new/2`, and it is the test to write first.
- `Functions.functions/0` and `Functions.base_context/0` agree: the resolved
  entry for `"In"` is `{1, {Statifier.Evaluator.Functions, :in_state}}` and its
  arity matches `functions/0`'s declaration.
- `base_context/0` is a constant: two calls return the same term, its `data` is
  empty and its `host` is `nil`.
- `put_configuration/2` changes `In/1`'s answer and leaves `data`,
  `functions` and `on_unbound` untouched.

Sabotage line on every one of them.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating
- [ ] Full `mix quality` green, verified through `mix gate.verify`
- [ ] `mix test.regression` at 1522/0
- [ ] `mix test --include scion --include scxml_w3` at exactly 1661 tests, 107 failures
- [ ] `grep -n "Predicator.Context.new" lib/statifier/evaluator.ex` returns nothing
- [ ] `mix run bench/context_build.exs` completes at every size point

#### Manual Verification:
- [ ] `T_full` is below the Phase 1 baseline by roughly the recorded `T_fixed`
      share (`T_fixed/T_full` was 56.6%, so expect a drop near half). "Roughly"
      is a judgment about magnitude against benchee's variance, which is why
      this is not an automated criterion: a drop far smaller than the fixed
      term means the hoist did not do what this plan claims, and is a finding
      to report rather than a number to accept.
- [ ] The seven datamodel writers were each checked for binary roots and the
      finding is in the commit body.
- [ ] `In(stateId)` still matches spec 5.10, read from the local spec cache.
- [ ] The equivalence test's datamodel genuinely covers the shapes
      `undefine_nils/1` and `normalize_value/1` disagree about, not just flat
      scalars.
- [ ] No Appendix D procedure was edited; no deviation comment is owed.

**Implementation Note**: same as Phase 1.

---

## Phase 3: Re-measure, repair the derivation, record the numbers

### Overview

Produce the before/after evidence the acceptance criterion asks for, and
repair the two things in `bench/` that no longer describe the code.

### Changes Required:

#### 1. Repair `bench/macrostep.exs`'s derivation constants

**File**: `bench/macrostep.exs`
**Changes**: The hardcoded build counts at `:269-272` (`7` and `n + 3`),
`:308` (`n + 4`) and `:350` (`2`) were read off the pre-ADR-0028 call-site
table and count one rebuild per `<assign>` and per `<foreach>` iteration -
rebuilds ADR-0028 removed. Restate them against the current call graph: two
selection-round builds plus one build per non-empty content block, with no
per-write rebuild. Update the comment blocks above each to cite ADR-0028 and
this plan rather than the superseded table.

This makes `S_time`/`S_mem` meaningful again rather than leaving them dead;
if the corrected estimate still disagrees with the measured macrostep by more
than it should, say so in the results doc instead of tuning the constant.

#### 2. Add the provider/host rows to `bench/context_build.exs`

**File**: `bench/context_build.exs`
**Changes**: Extend Run 1 with three scenarios the research measured ad hoc:
`Context.put_host/2`, `Context.resolve_functions/1` with a provider, and
`Context.resolve_functions/1` with an inline closure. They are the evidence
for "a provider swap by itself moves no number" and for "the fixed term is
what Phase 2 removed", and they belong in the committed script rather than in
a probe nobody can re-run.

#### 3. The results document

**File**: `bench/results/260814-st-l0t-provider-host-seam.md`
**Changes**: Append "After (Phase 2)" and "Comparison" sections to the Phase 1
baseline. Content:

- `measured macrostep` before/after per document family: `realistic`,
  `assign-heavy` at n in [1, 5, 25, 100], `foreach` at n in [1, 10, 100,
  1000], `cond-bearing selection`.
- `T_full`, `T_fixed`, `T_bind`, `put_host/2` and both `resolve_functions/1`
  rows, before and after, at every size point.
- An explicit statement of how the acceptance criterion's "per-block and
  per-selection-round builds reduced" is read here: **cost per build, not
  count of builds** - with the reasoning from this plan's resolved-question 2,
  and the note that a build-count reduction is available but deferred.
- The machine, Elixir/Erlang and benchee versions, and a note that the
  before and after rows come from the same machine in the same session.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green, verified through `mix gate.verify` (a `bench/`
      edit is outside every stage, so this confirms the phase introduced no
      unrelated change)
- [ ] `mix run bench/macrostep.exs` completes and prints a summary
- [ ] `mix run bench/context_build.exs` completes and prints all size points
- [ ] `bench/results/260814-st-l0t-provider-host-seam.md` contains both a
      Before and an After table over all four document families

#### Manual Verification:
- [ ] The after figures actually beat the before figures on the corpus-shaped
      documents. If they do not, stop and report - Phase 4's ADR must not be
      written against numbers that did not appear.
- [ ] The repaired build counts match the call graph as the implementer reads
      it, not as this plan asserts it; a disagreement is a finding to record.
- [ ] Benchee's own noise warnings were read, not skipped, and any figure
      inside noise is reported as noise rather than as a win.
- [ ] The cost-not-count reading of the acceptance criterion is stated in this
      phase's commit body in the plan's own words, so it reaches the human
      closing the bead as a decision to affirm rather than as prose to find.

**Implementation Note**: same as Phase 1. `bench/` is ungated by design
(`bench/README.md`), so the gate confirms cleanliness rather than correctness
here; the manual criteria carry this phase.

---

## Phase 4: ADR-0029 and the documentation rewrite

### Overview

Record the storage decision on its new grounds, and rewrite the prose that
still argues from the closure.

### Changes Required:

#### 1. ADR-0029

**File**: `docs/adr/0029-<kebab-title>.md` (next free number; 0028 is the
highest today)
**Changes**: Status accepted, dated. Structure follows ADR-0028's:

- **Context**: what the seam is; the three measured facts; that ADR-0028
  deferred exactly this question and named the two grounds it was gated on.
  Cite Phase 3's results document for every number.
- **Decision**: `In/1` is a provider, the functions map is resolved once at
  compile time, the configuration arrives per site through `put_host/2` - and
  **no context is stored on `%MachineState{}`, and the threaded interval is
  not widened across blocks or microsteps.**
- **Grounds, restated** - the substance of the record:
  - Ground 1 (non-resumability) **dissolves**. Its own text made itself
    contingent on the closure (`evaluator.ex:50-52`), the contingency is met,
    and a test now asserts mechanically that no `function()` value survives in
    a built context.
  - Ground 2 (staleness) **does not dissolve, and changes species**. It stops
    being "stale by construction" and becomes an exhaustiveness obligation:
    one `put_host/2` for the configuration, and a bind at each of seven
    datamodel write sites, two of which bind into no context today. ADR-0028's
    "survives the px-8ii seam entirely" is too strong as written and this
    record says so.
  - Ground 3, new: a stored context duplicates state `%MachineState{}` already
    holds - its `data` against `machine_state.datamodel`, its `host` against
    `machine`/`configuration`. Two fields that must agree and can silently
    disagree is a different constraint-1 failure mode from a closure, related
    to the sharp edge `machine_state.ex:169-180` already documents.
  - Host width: `{machine, configuration}`, with the narrowing to
    `{id_to_index, configuration}` recorded as the reversible alternative and
    why it is not needed while nothing is stored.
- **Consequences**: ADR-0012 constraint 1 untouched (nothing stored);
  `docs/datamodel.md`'s "once per evaluation site" commitment unchanged - this
  changes what a build costs, not how long an interval lasts; `px-rnc`'s
  upstream memoization would make the compile-time hoist redundant rather than
  wrong, and predicator owns its shape (ADR-0025 rule 1); the build-count
  reduction remains future work, and what would reopen it.

Before writing the `px-rnc` paragraph, re-read `px-rnc` in predicator-ex and
write a new dated reconciliation note above the old one on `st-l0t` - CLAUDE.md
requires that before citing a mirrored bead's status.

#### 2. The `Statifier.Evaluator` moduledoc

**File**: `lib/statifier/evaluator.ex`
**Changes**: Rewrite `:37-84` ("Why the built context is not a `MachineState`
field"). It keeps its conclusion and loses its first argument. Retitle it so
the title is not a claim the body no longer makes on the old basis - the
section is now about what a context costs and why it is still not stored.
State the three grounds as ADR-0029 states them, cite ADR-0029 rather than
re-arguing it, and describe the current construction: a compile-time base
context, `put_host/2` per site, `bind/3` per root.

Also update:
- the "The three `Context`s" section (`:9-23`), which describes
  `Predicator.Context.t()` as carrying "the `In/1` host function" - accurate
  by accident, now accurate on purpose, and worth one clarifying clause;
- the parenthetical at `:20-21`, "once a later phase adds that field", which
  ADR-0028 already made stale;
- the "Never scoped to a whole macrostep" section (`:25-35`) - its argument is
  unchanged and stays, but the sentence naming `In(stateId)`'s captured
  configuration should name the host term instead.

#### 3. `docs/datamodel.md`

**File**: `docs/datamodel.md`
**Changes**: The upstream-seams entry at `:118-141` says the provider/host
seam is "Not taken here yet: `In/1` is still an inline `functions:` closure".
Rewrite that to record it as taken, in the per-site-cost form rather than the
widened-interval form, and keep the closing sentence - no context is stored on
`MachineState` and widening the interval remains future work - because it is
still true and is now true by decision rather than by omission. Cite ADR-0029.

The "once per evaluation site" commitment at `:54-59` is unchanged; say so
rather than leaving the reader to infer it.

#### 4. Changelog

**File**: none.
**Changes**: No fragment. Per `changelog.d/README.md`, the v2-unreleased rule
is "write a fragment when v2 differs from v1", and nothing here differs from
v1 in a way a caller of the public API could observe: same `In()` semantics,
same errors, same results, faster. `Statifier.Evaluator.put_configuration/2`
is a new public function, but `Statifier.Evaluator` has no v1 counterpart, so
its addition is invisible to someone upgrading. This decision is stated here
so the implementer does not re-litigate it, and so a reviewer can disagree
with it on the record.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green, verified through `mix gate.verify`
- [ ] `mix quality --profile merge` green - this is the profile that enables
      the ADR judge stage, and a new ADR is exactly what it exists to read
- [ ] `mix adr.check` clean
- [ ] `mix test.regression` at 1522/0 (the moduledoc edit touches a compiled
      file, so the suite still runs)
- [ ] `grep -n "px-8ii" lib/ docs/` returns only references that still make
      sense after the rewrite

#### Manual Verification:
- [ ] The `mirrors: px-10u` / `px-rnc` reconciliation notes were re-read in
      predicator-ex and a new dated note was written on `st-l0t` before the
      ADR cited either.
- [ ] ADR-0029 does not re-argue ADR-0028 or ADR-0012; it cites them.
- [ ] The moduledoc's rewritten section would let a reader who has never seen
      this plan answer "why is there no context on `MachineState`" correctly.
- [ ] House style: `docs/adr/` and `docs/datamodel.md` are hyphen-only ASCII
      prose today; the new ADR matches its neighbors.

**Implementation Note**: same as Phase 1. This phase touches `lib/` only in
`@moduledoc` prose, so the spec-conformance manual criterion is satisfied by
inspection: no function body changes.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/evaluator/functions_test.exs` (new): `functions/0`'s
  declared entry, `in_state/2` over a host with the state present, absent, and
  undeclared, `base_context/0`'s constancy and emptiness, and the agreement
  between `functions/0` and `base_context/0`'s resolved entry.
- `test/statifier/evaluator_test.exs`: the closure-freeness assertion
  (ground 1, mechanical), the host shape, `put_configuration/2`'s effect and
  non-effect, and the `new/2` equivalence test that justifies bypassing
  `new/2`.
- The existing `In/1` and snapshot tests (`:133-181`) must pass **unedited**
  through both code phases. Needing to edit one is a signal to stop.
- Every new test asserting `lib/` behavior carries its sabotage line; the
  mutation is performed, observed red, and reverted, not imagined.

Key edge cases: an id the machine never declared (`Machine.index/2`'s `:error`
branch, the only test reaching it today is `evaluator_test.exs:153-156`); a
`nil` root and a nested `nil` through the per-root bind path; `_event` before
any event has arrived (`:202-207`); a datamodel root whose value is a struct,
which `undefine_nils/1` deliberately does not walk.

### Manual Testing Steps:

1. In `iex -S mix`, compile a document with `In()` in a `cond` - the shape
   `test/scion_tests/in/test_in_predicate_test.exs` uses - step it with
   `Statifier.Interpreter.microstep/1`, and confirm `In()` answers against the
   configuration at each step.
2. Build a context with `Statifier.Evaluator.context/1`, inspect it, and
   confirm by eye that nothing in it prints as `#Function<...>`.
3. Take that context, `put_configuration/2` it against a machine_state with a
   different configuration, and confirm `In/1`'s answer moves while `data`
   does not.
4. Confirm the corpus counts by hand once at the end:
   `mix test --include scion --include scxml_w3` and `mix test.regression`.

## Corpus/Ratchet Notes

No corpus regeneration and no `test/passing_tests.json` edit is expected.
`internal_tests` is glob-based (`test/statifier/**/*_test.exs`), so the new
unit tests join the ratchet with no JSON change; `scion_tests` and `w3c_tests`
are explicit arrays and this plan changes no conformance result.

The counts to reproduce exactly, at every phase boundary: **1661 tests, 107
failures** for `mix test --include scion --include scxml_w3`, and **1522/0**
for `mix test.regression` (ADR-0028's Phase 4 record,
`docs/adr/0028-...:117-119`).

If a conformance test newly passes, that is a surprise, not a win to bank
quietly: record it in the commit body, then add it with
`mix test.baseline add <file>`. Shrinking `test/passing_tests.json` is a
guarded change needing a ledger entry in `docs/quality-gate-changes.md`
(ADR-0011) and is a human's call, not an agent's.

## Performance Considerations

The change is a cost reduction per build, not a reduction in the number of
builds. Expected shape, from `bench/results/260814-context-build.md`:

- `T_fixed` (the `resolve_functions/1` term) was 1.29 us / 5.51 KB of
  `T_full`'s 2.28 us / 10.92 KB at `:corpus` - 56.6% of a build's time. Phase 2
  removes it from runtime entirely, so a build should land near `T_full -
  T_fixed`.
- Context construction was 62.0% of a macrostep's wall time and 67.1% of its
  allocation, so a ~50% cheaper build should show as roughly a 30% cheaper
  macrostep on corpus-shaped documents, and more on `<foreach>` where the
  share is higher.
- `put_host/2` at 0.0478 us is ~1.9% of a `:corpus` build and is not expected
  to be visible.

Two things that would make the numbers disappoint, both worth reporting rather
than tuning away: predicator's `normalize_value/1` dominating at larger
datamodels, which would make the fixed term a smaller share than 56.6%; and
per-root `bind/3` costing more than one whole-map `normalize_value/1` walk at
high root counts, which would show as `T_full` failing to drop. The stress size
points in `bench/support/workload.exs` already cover both directions.

`px-rnc`, if predicator takes it, memoizes the same term upstream and would
make the compile-time hoist redundant. That is a reason to expect the win to
be temporary in a future predicator, not a reason to skip it now.

## References

- Source research: `docs/research/260814-st-l0t-provider-host-seam-for-in1.md`
- Related ADRs: `docs/adr/0028-executable-content-blocks-thread-one-context.md`
  (the deferral this plan answers), `docs/adr/0012-debuggability-designed-into-the-core.md`
  and `docs/observability.md` (constraint 1),
  `docs/adr/0004-predicator-as-the-datamodel.md`,
  `docs/adr/0005-full-configuration-and-interned-state-indexes.md`,
  `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`
- Prior plan and results: `docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`,
  `bench/results/260814-context-build.md`, `bench/results/260814-macrostep.md`
- Upstream source: `deps/predicator/lib/predicator/functions/provider.ex:1-52`,
  `deps/predicator/lib/predicator/context.ex:128-136,158-207,240-260`,
  `deps/predicator/lib/predicator/evaluator.ex:1289-1325`
- Bead: `st-l0t` (mirrors `px-10u`; complements, not blocks)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The post-swap `T_full` reproduces the Before `T_full` **within noise**,
      confirming the research's central correction that a provider swap by
      itself moves no number. This is a judgment about benchee's variance, not
      a threshold a script can decide, so it is deliberately not an automated
      criterion - if the two differ by more than noise, stop and report rather
      than proceeding to Phase 2 on an unexplained delta.
- [ ] The `In(stateId)` semantics still match spec 5.10: true exactly when
      `stateId` names a state in the current configuration, and an undeclared
      id answers "not active" rather than raising. Read the clause locally
      from the spec cache, do not recall it.
- [ ] No Appendix D procedure was edited, so no ADR-0002 deviation comment is
      owed (ADR-0002 applies to the interpreter ports; `Statifier.Evaluator`
      is not one).
- [ ] The moved `:error` -> `{:ok, false}` comment still reads as the reason
      for the answer, not as a description of the code below it (ADR-0018).

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving on. In looped (`--loop`)
execution, the Automated Verification list gates advancement via
`/wurk:commit --auto`, and Manual Verification items are deferred and
surfaced once at the end.

---
