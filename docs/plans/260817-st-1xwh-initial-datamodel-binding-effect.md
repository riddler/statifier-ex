---
date: 2026-08-17
planner: Claude
git_commit: 102eedce9dab0536d31c632f789e29fa84efabea
branch: st-1xwh-initial-datamodel-effect
repository: statifier-ex
beads_issue: st-1xwh
topic: "The initial datamodel joins the effect stream: an init baseline effect plus a per-<data> binding effect"
tags: [plan, datamodel, effects, observability]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# Initial datamodel binding effect Implementation Plan

## Overview

Put the *starting* datamodel on the effect stream, so a consumer that folds
effects alone reconstructs the whole datamodel from nothing - not just every
change to it. Two pieces: one new core effect
`{:datamodel_init, %Statifier.Effect.DatamodelInit{}}` carrying the datamodel
as it stands after spec 5.3.3's unconditional `<data>` creation and before any
`<data>` value is evaluated, and a `d_index`-identified
`{:datamodel_change, _}` per `<data>` actually bound, emitted from the same
`bind_value/4` under both `binding="early"` and `binding="late"`. Bead:
st-1xwh (mirrors `sui-t36.1`).

This closes decision 6 of
`docs/plans/260816-st-oef3-assign-datamodel-change-effect.md`, which scoped
st-oef3 to datamodel *writes* and named this half as a follow-up. That plan's
ten decisions are the settled ground this one builds on; the three questions
the bead raises are decided below under "Decisions", in the same form.

## Current State Analysis

- `Statifier.Interpreter.Datamodel.initialize/1`
  (`lib/statifier/interpreter/datamodel.ex:277-300`) returns a bare
  `MachineState.t()`. Its own `@doc` (`:264-275`) reasons the omission
  explicitly and declines to invent the shape early, naming a future trace row
  as the thing that would add a second return value. That prose is what this
  plan supersedes.
- `Statifier.Interpreter.Datamodel.enter_state/2` (`:426-436`) is the same
  shape: bare `MachineState.t()`, no effect list.
- `Statifier.Interpreter.initialize/2` **already** returns
  `{MachineState.t(), [Effect.t()]}` (`lib/statifier/interpreter.ex:217-284`)
  and concatenates `global_effects ++ enter_effects ++ loop_effects` at
  `:283`. There is a return slot waiting; `Datamodel.initialize/1` at `:249`
  is simply the one call in that body that contributes nothing to it.
- `Statifier.Interpreter.ExitEntry.arrive/3`
  (`lib/statifier/interpreter/exit_entry.ex:703-745`) already returns
  `{machine_state, onentry_effects ++ default_entry_effects ++
  completion_effects}`. Its call to `Datamodel.enter_state/2` (`:734`) sits
  behind the `first_entry?` gate captured at `:725`, after `entered_states` is
  written at `:727-730` (the order the existing comment at `:717-724` explains
  and this plan does not disturb), and contributes no effects.
- `Statifier.MachineState.new/2` (`lib/statifier/machine_state.ex:415-457`)
  builds `datamodel: Map.merge(author_datamodel,
  SystemVariables.initial(machine, session_id))` at `:448` - the `:datamodel`
  option merged *under* the four spec 5.10 system variables, so a system
  variable can never be shadowed. `SystemVariables.initial/2`
  (`lib/statifier/evaluator/system_variables.ex:75-85`) produces `_sessionid`,
  `_name`, `_event`, `_ioprocessors`. Both run inside a constructor, before
  any effect list exists.
- `Statifier.Machine.Data` (`lib/statifier/machine/data.ex:35-46`) already
  carries `d_index`, `id`, `value`, `location`, and `value_location`, and
  `Statifier.Machine.data/2` (`lib/statifier/machine.ex:190-196`) resolves a
  `d_index` back to it. `d_index` is dense from 0 in document order, assigned
  by `Statifier.Compiler` (`lib/statifier/compiler.ex:497-517`) the same way
  `t_index` and `c_index` are, and `machine/data.ex:4-5` cites ADR-0012 item 3
  as its basis.
- **But no document names `d_index` as an identity.** `docs/observability.md`
  constraint 3 (`:94-115`) and its seams table (`:190`) name only
  `t_index`/`c_index`; ADR-0012 item 3 (`:38-41`) summarizes the same two. A
  grep of `docs/adr/` for `d_index` returns nothing. The identity exists in
  the compiler and in `Machine.Data`, and is undocumented in the observability
  vocabulary that governs what an effect may carry.
- `Statifier.Effect.DatamodelChange`
  (`lib/statifier/effect/datamodel_change.ex`) carries `location_path`,
  `location_source`, `new_value`, `prior_value`, `c_index` (nil-able),
  `owner` (nil-able), `macrostep`, `microstep`. It has no `d_index`.
- `Statifier.Session.Telemetry.location/2`
  (`lib/statifier/session/telemetry.ex:625-641`) dispatches on **field name
  present on the struct map**, in clause order `c_index`, then `state_index`,
  then `t_index`, then a catch-all `nil`. A payload carrying both `c_index`
  and `d_index` matches the `c_index` clauses first, so a `d_index` added to
  `DatamodelChange` resolves to `nil` unless a clause is placed **above**
  them.
- The consumption path is uniform for init-time effects. `Session.init/1`
  destructures `Interpreter.initialize/2`'s pair (`lib/statifier/session.ex:523`)
  and defers them to `handle_continue({:initialize, effects, ...})` (`:566`,
  `:616-631`), which runs the same `perform/3` (`:912-919`) every later input
  runs. An effect produced during initialization reaches subscribers and
  telemetry with no special casing. `test/statifier/session/datamodel_reconstruction_test.exs`
  already relies on this for the three `<onentry>` `<assign>`s in its fixture.
- `Statifier.Replay.perform_instruction/3` (`lib/statifier/replay.ex:359-366`)
  has a generic `{:notify, effect}` clause and no per-tag dispatch, so a
  notify-only effect needs no replay change (ADR-0034).
- The current vocabulary is 10 core + 9 trace = 19 tags. Counts asserted:
  `test/statifier/effect_test.exs:132-134` (19),
  `test/statifier/session/effects_test.exs:326-328` (22 fixtures),
  `test/statifier/session/telemetry_test.exs:225-235` (26 telemetry event
  names). `telemetry.ex:136-149` heads its table "Core effect events (10)",
  and `telemetry_test.exs:242-254` asserts that table and `events/0` agree.
- The stated gap lives in a test comment today:
  `test/statifier/session/datamodel_reconstruction_test.exs:43-52` writes
  `@starting_datamodel` as a literal and names decision 6 as the reason.

## Desired End State

After this plan, a consumer that has subscribed to a `Statifier.Session` and
holds **no** other channel - no `Session.snapshot/1` call, no `%Machine{}`
handle for values - reconstructs the datamodel at any point by:

1. taking the one `{:datamodel_init, %DatamodelInit{}}` effect's `datamodel`
   map as the starting map, and
2. folding every subsequent `{:datamodel_change, %DatamodelChange{}}` effect
   onto it by writing `new_value` at `location_path`.

Every datamodel key is reproduced exactly, with one stated exception:
`"_event"`, whose sole writer is `MachineState.put_event/2` and which is out
of scope by decision 8.

Both `<data>` bindings and `<assign>`-family writes travel as
`:datamodel_change`, distinguished by which identity field is non-nil
(`d_index` for a binding, `c_index` for a content-block write, neither for the
two runner-side writes). This holds under `binding="early"` and
`binding="late"`, with an author-supplied `:datamodel` option, and with
`trace: false`.

Verify with: full `mix quality` green;
`test/statifier/session/datamodel_reconstruction_test.exs` passing with
`@starting_datamodel` deleted and the starting map taken off the stream;
`Statifier.Session.Telemetry.events/0 |> length() == 27`.

### Key Discoveries:

- `Interpreter.initialize/2` already returns `{machine_state, [effect]}` and
  concatenates three effect lists at `lib/statifier/interpreter.ex:283`, so
  the init-time effect needs a fourth list at that one site, not a new plumbing
  layer.
- `ExitEntry.arrive/3` already returns `{machine_state, effects}`
  (`lib/statifier/interpreter/exit_entry.ex:703-745`) and already gates
  `Datamodel.enter_state/2` on `first_entry?`, so the late-binding effect needs
  one more accumulator in a function that already has three.
- `Machine.Data` retains `location` and `value_location` on the struct itself
  (`lib/statifier/machine/data.ex:35-46`), so `Machine.data(machine, d_index).location`
  is a working ADR-0040 location resolution with no side table - the same
  relationship `Machine.content/2` has to a `c_index`.
- `Telemetry.location/2`'s field-name dispatch
  (`lib/statifier/session/telemetry.ex:625-641`) is ordered, and its first
  clause pair is `c_index`. A `d_index` clause must precede them or it is
  dead. `%DatamodelChange{}` is the only payload that will carry a `d_index`.
- `Session`'s init-time effects go through the identical
  `Effects.plan/2` -> `perform_instruction/3` -> `notify/2` path as every
  later effect (`lib/statifier/session.ex:566`, `:616-631`, `:912-936`), so
  nothing new is needed to deliver an effect emitted before the first event.
- ADR-0037 spells an unbound value `:undefined`, and
  `Datamodel.initialize/1`'s `seed/2` (`:306-311`) already writes exactly that
  for every declared id.
- `docs/observability.md:173-179` names "no wire format" as an explicit
  non-goal, and ADR-0025 puts serialization on statifier-ui's side of the
  mirror.
- ADR-0040 carries three dated amendments already (st-f6i9, st-ii9v, st-oef3),
  which is the established form for adding an event or narrowing a rule.

## Decisions

The bead's three questions, plus the four the work raises, decided. These are
the plan's contract; the implementer does not re-open them.

**1. Both an init baseline effect and per-`<data>` binding effects - and the
baseline is taken *before* binding, not after.** The bead frames this as an
either/or; the codebase makes it neither.

A snapshot alone cannot work, because `binding="late"` binds a state-scoped
`<data>` at state entry, arbitrarily far into the run
(`lib/statifier/interpreter/datamodel.ex:451-463`, spec 5.3.3: "MUST assign
the specified initial value to a given data element only when the state that
contains it is entered for the first time"). One init-time snapshot cannot
describe a value that does not exist yet, so late binding forces per-binding
effects regardless.

Per-binding effects alone cannot work either, because three parts of the
starting datamodel are produced by no `<data>` binding at all: the
`MachineState.new/2` `:datamodel` option, `SystemVariables.initial/2`'s four
spec 5.10 variables, and the `:undefined` seed that spec 5.3.3's unconditional
creation writes for every declared id. A top-level `<data>` whose id the
environment supplied is *skipped* entirely (`datamodel.ex:341-345`), and a
`<data>` whose value fails to evaluate emits nothing under decision 5 - both
leave a datamodel entry that no binding effect describes.

So: one `{:datamodel_init, _}` carrying the map after `seed/2` and before the
binding fold, then one `{:datamodel_change, _}` per `<data>` actually bound.
Taking the baseline *pre*-binding rather than post- is what makes the stream
monotone and non-redundant: every effect after the first adds information, no
effect restates another, and the fold is exact rather than
apply-then-overwrite. It also gives the baseline a crisp definition a reader
can hold - "the datamodel that no binding effect can ever describe" - rather
than "the datamodel, again, at an arbitrary moment".

**2. The baseline is unconditional.** `{:datamodel_init, _}` is emitted on
every `initialize/2`, including for a chart with no `<datamodel>` at all: the
four system variables are always present, so the map is never empty and a
consumer always gets a starting point without having to special-case its
absence.

**3. Binding effects reuse `:datamodel_change` with a `d_index`, and carry
`owner: nil`.** A `<data>` binding *is* a datamodel write, and every field
`DatamodelChange` already has is meaningful for one: `location_path` is
`[id]`, `location_source` is the id, `new_value` is the bound value,
`prior_value` is what stood there (the `:undefined` seed, or an earlier
`<assign>`'s value in the late case). A second near-identical struct would
duplicate six of eight fields and force `Effects.plan_one/2`, `core_shape/2`,
ADR-0040, and both fixture tables to carry two parallel rows for one concept,
and - the argument that decides it - would make the bead's own criterion a
*two*-tag fold instead of a one-tag fold over one starting map.

The identity is a new nil-able top-level `d_index` field, not a `c_index`, for
the reason the bead gives: a `<data>` element is not executable content,
`Machine.content/2` cannot resolve it, and `Machine.Content.owner/0` has no
case for it. This is `DatamodelChange`'s existing pattern, not a new one - it
already carries a nil-able `c_index` precisely so writes from constructs that
are not content blocks can travel on it (st-oef3 decision 3).

`owner` is `nil` for a binding. `owner`'s type is `Machine.Content.owner()`
widened once for `<invoke idlocation>`; it answers "which content block did
this write belong to", and a `<data>` binding belongs to none. `nil` is the
honest answer, exactly as `c_index: nil` is honest for the two runner-side
writes. **No redundant second spelling of the same fact**: the error channel
already names a failed binding `{:data, d_index}`
(`datamodel.ex:476-478`, via `MachineState.raise_platform/4`), and mirroring
that tuple into `owner` alongside a `d_index` field would put the same integer
on the payload twice. `d_index != nil` is itself the discriminator that says
"this was a binding".

**4. `MachineState.new/2`'s `:datamodel` option and `SystemVariables.initial/2`
get no identity of their own; they ride on the baseline effect.** Three
reasons. (a) They run inside a constructor, before `Interpreter.initialize/2`
has produced anything - ADR-0003's shape is
`(machine_state, event) -> {machine_state, [effect]}`, and `new/2` is neither
a step nor an event; giving it an effect list would invent a return shape for
a function with no loop position. (b) They have no identity to carry: an
environment-supplied key has no `<data>` element and therefore no `d_index`,
and a system variable is spec 5.10's, not the document's - there is nothing
for constraint 3 to name. (c) The baseline effect observes their result
exactly, because `Datamodel.initialize/1`'s first act is to read
`machine_state.datamodel`'s keys as `env_ids` (`datamodel.ex:279`) - the
environment's contribution is, definitionally, what is in that map when this
module starts. One effect at that point captures both, correctly, with no new
seam.

**5. A failed or skipped binding emits nothing.** Symmetric with st-oef3
decision 9 and for the same reason: the datamodel did not change beyond the
`:undefined` the baseline already reported, so a reconstruction has nothing to
apply, and the failure is already observable as `error.execution` with origin
`{:data, d_index}` on the event channel (`datamodel.ex:471-478`). An
environment-skipped top-level `<data>` (`datamodel.ex:341-345`) likewise emits
nothing: its value is the environment's, and the baseline already carries it.

**6. The baseline carries the datamodel map and the counters, nothing else.**
Not `binding`, not `env_ids`, not the declared-id list - all three are facts
about the `%Machine{}`, and `docs/observability.md:94-115` constraint 3's
model is that tooling resolves machine facts through the machine. What the
map carries instead is *values*, which are not in the machine: the
environment's `:datamodel` option and the session's `_sessionid` exist nowhere
else. The rule is "values ride on the effect, machine structure does not",
and it is the same rule `DatamodelChange`'s `new_value`/`prior_value` already
follow. This also keeps the payload clear of `MapSet`s, which no effect
payload in this vocabulary carries as a value.

The map is a term reference, not a deep copy - Elixir maps are immutable, so
the baseline costs one word, once per session, not O(datamodel size).

**7. `d_index` is documented as a constraint-3 identity, in
`docs/observability.md` and in a dated ADR-0012 amendment.** The index already
exists and the compiler already cites ADR-0012 item 3 for it
(`lib/statifier/machine/data.ex:4-5`), but neither `docs/observability.md`
constraint 3 nor ADR-0012 item 3 enumerates it, so an effect carrying one
would be carrying an identity the observability vocabulary does not admit.
Both get the third index named, ADR-0012 by a dated
`**Amendment (st-1xwh):**` paragraph in the form ADR-0040 already carries
three of. This is completing an enumeration that fell behind the compiler, not
minting a new identity kind, and the amendment says so.

**8. `_event` is out of scope, and the acceptance criterion is stated with
that exception on the record.** `"_event"` is not written through
`write_location/4` or through any binding: `MachineState.put_event/2`
(`lib/statifier/machine_state.ex:596-605`) is "the one and only writer of
`datamodel["_event"]`", and it fires on every dequeue, inside the loop, with
no effect list of its own. So after this plan a stream fold reproduces every
datamodel key exactly, **except** `"_event"`, which the baseline reports as
the `:undefined` `SystemVariables.initial/2` seeded and which then diverges
from the live datamodel as events are processed.

This is deliberate, not a residual gap. `_event` is spec 5.10's *current
event under evaluation*, not authored or assigned datamodel content; a data
inspector wants the event stream for it, and the event that produced any given
value is already on the effect stream in its own right. Emitting a
`:datamodel_change` per dequeue would put one effect per event on the stream
carrying a whole event struct as a "datamodel value", restating information
the event channel already carries - which is st-oef3 decision 9's argument in
a different costume.

The consequence for Phase 3 is concrete: the oracle assertion against
`Session.snapshot/1` compares every key **but** `"_event"`, and the test says
why in a comment rather than silently narrowing. The reconstruction assertion
itself is unaffected, since it never claimed `_event`.

**9. No new row in `docs/observability.md`'s constraint-2 table, and no new
ADR beyond the two amendments.** Same reasoning as st-oef3 decision 10, and it
applies twice over here: constraint 2 is the *trace* vocabulary and both
effects in this plan are core, and constraint 2's own row-admission test
(`docs/observability.md:72-78`) is "a phase boundary Appendix D itself names
inside `mainEventLoop`". Datamodel initialization is named by `interpret`, not
by `mainEventLoop`, and per-`<data>` binding is not a boundary at all. Adding
a core member is a bead-level decision here (`lib/statifier/effect.ex:113`);
ADR-0040 gets the event row it makes itself the authority for, and ADR-0012
gets the identity, and nothing else changes.

## What We're NOT Doing

- Not emitting a *second* snapshot at any later point. The baseline is emitted
  once, and everything after it is a change (decision 1).
- Not making either effect trace-gated. Reconstruction must work with
  `trace: false`, which is st-oef3 decision 1's argument unchanged.
- Not giving `MachineState.new/2` or `SystemVariables.initial/2` an effect
  list or a return-shape change of any kind (decision 4).
- Not adding a second effect tag for bindings (decision 3).
- Not carrying `binding`, `env_ids`, or the declared-id list on the baseline
  payload (decision 6).
- Not emitting on a failed or environment-skipped binding (decision 5).
- Not putting `"_event"` on the stream: `MachineState.put_event/2` gains no
  effect and no return-shape change (decision 8).
- Not defining a serialization or wire format for the baseline map or for
  `:undefined` - `docs/observability.md:173-179` makes that an explicit
  non-goal here and ADR-0025 puts it on statifier-ui's side.
- Not changing `Statifier.Replay`: both effects plan only to `{:notify, _}`,
  which `replay.ex:359-366`'s generic clause already handles (ADR-0034).
- Not changing `Statifier.initialize/2` (`lib/statifier.ex:120-123`), a
  pass-through whose `{MachineState.t(), [Effect.t()]}` spec is already
  correct.
- Not touching `docs/observability.md`'s constraint-2 trace table (decision 9).
- Not refreshing the bead's `mirrors: sui-t36.1` line: `sui-t36.1` is not
  resolvable from this tracker, which the bead's own description records. Per
  ADR-0025 that is a note to refresh before *scheduling or citing status*, and
  this plan does neither; it is recorded under "Residual open questions"
  instead.

## Implementation Approach

Three phases, each independently committable and independently green.

Phase 1 adds the baseline effect end to end: the vocabulary member and every
exhaustive enumeration it must join, plus emission from
`Datamodel.initialize/1` and threading through `Interpreter.initialize/2`. It
is self-verifying - the effect is produced in the same phase that declares it,
so its own tests prove it rather than waiting on a later phase.

Phase 2 adds the per-`<data>` binding effect: the `d_index` field, the
identity's documentation, emission from `bind_value/4`, and the return-shape
change to `enter_state/2` that late binding needs. Also self-verifying.

Phase 3 is the acceptance criterion: the reconstruction test stops writing its
starting map as a literal and takes it off the stream instead, with late
binding and an environment-supplied `:datamodel` covered.

The order matters in one direction only: Phase 2's binding effects are
meaningless for reconstruction without Phase 1's baseline to fold onto, and
Phase 3 needs both. Neither Phase 1 nor Phase 2 depends on Phase 3.

### The Appendix D rule

No Appendix D pseudocode changes, and **this plan introduces no deviation from
Appendix D**. Two placements are worth stating so the implementer does not
have to re-derive them:

- `Datamodel.initialize/1`'s effects are concatenated **ahead of**
  `global_effects` at `lib/statifier/interpreter.ex:283`, matching the
  pseudocode's own ordering at `appendix-d.txt:101-102`, which the call site's
  existing comment block (`interpreter.ex:251-267`) already quotes: "Initialize
  the global data structures, including the data model... Then execute the
  global `<script>` element, if any."
- `Datamodel.enter_state/2`'s effects are concatenated **ahead of**
  `onentry_effects` in `arrive/3`, matching `appendix-d.txt:311-313`, where
  `initializeDataModel(datamodel.s, doc.s)` precedes the `onentry` loop, and
  matching spec 5.3.3's "before any `<onentry>` markup".

`Statifier.Interpreter.Datamodel` has no procedure body to port at all - its
own moduledoc (`datamodel.ex:6-44`) records that `initializeDatamodel` /
`initializeDataModel` appear in Appendix D only as two mutually inconsistent
call sites, and that this module's semantics come from clause 5.3.2 / 5.3.3 /
B.2.2 prose. Both functions keep their existing control flow exactly; only
their return values grow.

---

## Phase 1: `:datamodel_init` joins the vocabulary and is emitted

### Overview

The eleventh core effect, produced by `Datamodel.initialize/1` immediately
after seeding and threaded out through `Interpreter.initialize/2`.

### Changes Required:

#### 1. The payload

**File**: `lib/statifier/effect/datamodel_init.ex` (new)
**Changes**: the struct, modeled on `Effect.DatamodelChange`
(`lib/statifier/effect/datamodel_change.ex`).

```elixir
  @enforce_keys [:datamodel, :macrostep, :microstep]
  defstruct [:datamodel, :macrostep, :microstep]

  @type t :: %__MODULE__{
          datamodel: map(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
```

The moduledoc states, by number, what the map is and is not: it is the
datamodel after spec 5.3.3's unconditional `<data>` creation and **before** any
`<data>` value is evaluated (decision 1), so it carries exactly the three
contributions no binding effect can describe - `MachineState.new/2`'s
`:datamodel` option, `SystemVariables.initial/2`'s four spec 5.10 variables,
and the `:undefined` seed for every declared id (ADR-0037's spelling,
decision 4). It records that it is emitted unconditionally, once per
`initialize/2`, even for a chart with no `<datamodel>` (decision 2); that it
deliberately carries no `binding`, `env_ids`, or declared-id list because
those are `%Machine{}` facts a consumer resolves through the machine
(decision 6); and that it commits to no wire format
(`docs/observability.md:173-179`, ADR-0025).

#### 2. Emission in `Datamodel.initialize/1`

**File**: `lib/statifier/interpreter/datamodel.ex`
**Changes**: `initialize/1`'s `@spec` becomes
`MachineState.t() -> {MachineState.t(), [Effect.t()]}`. The baseline effect is
built from the machine_state as it stands **after** `seed/2` and **before**
the binding fold - a comment says so, citing decision 1, because building it
after the fold would restate values the binding effects already carry.

```elixir
    machine_state = seed(machine_state, machine)

    init_effect =
      {:datamodel_init,
       %Effect.DatamodelInit{
         datamodel: machine_state.datamodel,
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep
       }}
```

The existing `Enum.reduce/3` over `d_indexes` keeps its shape and its
accumulator stays a bare `machine_state` **in this phase** (Phase 2 widens
it); the function returns `{machine_state, [init_effect]}`.

**The `@doc` at `:253-275` must be rewritten, not appended to.** Its closing
paragraph currently reasons that this function returns a bare
`MachineState.t()` because binding produces no effect, and predicts that "a
future trace row would add the second return value at that point". That
prediction is now wrong twice over - the second return value arrives, and it
arrives as a *core* effect rather than a trace row, for st-oef3 decision 1's
reason. Replace the paragraph with one that states the new shape and cites
this plan's decision 1.

#### 3. Threading in `Interpreter.initialize/2`

**File**: `lib/statifier/interpreter.ex`
**Changes**: `:249` becomes
`{machine_state, datamodel_effects} = Datamodel.initialize(machine_state)`,
and `:283` becomes
`{machine_state, datamodel_effects ++ global_effects ++ enter_effects ++ loop_effects}`.
The existing comment block at `:251-275`, which already explains why
`global_effects` is threaded separately and prepended rather than folded, gains
one sentence naming `datamodel_effects` as the list that now precedes it and
citing `appendix-d.txt:101-102` for the ordering (see "The Appendix D rule").

#### 4. `Statifier.Effect`

**File**: `lib/statifier/effect.ex`
**Changes**: a row in the moduledoc vocabulary table (`:24-44`) whose
"Produced by" cell names
`Statifier.Interpreter.Datamodel.initialize/1`; a
`| {:datamodel_init, DatamodelInit.t()}` member in `@type core` (`:117-127`);
the `@typedoc` at `:116` changing "ten core effects" to "eleven"; the alias;
and the produced-list prose at `:46-50` gaining `:datamodel_init`.

#### 5. `Session.Effects`

**File**: `lib/statifier/session/effects.ex`
**Changes**: one `plan_one/2` clause beside `:datamodel_change`'s at `:150`:

```elixir
  defp plan_one({:datamodel_init, _init} = effect, _session_id), do: [{:notify, effect}]
```

and the moduledoc sentence at `:108-109` gains `:datamodel_init` to its list.

#### 6. `Session.Telemetry`

**File**: `lib/statifier/session/telemetry.ex`
**Changes**, each an exhaustive enumeration that must move together:

- the moduledoc table header at `:136` becomes "Core effect events (11)", plus
  a row for `[:statifier, :session, :effect, :datamodel_init]` with
  measurements `macrostep`, `microstep` and metadata `session_id`, `effect`,
  `location`, `datamodel`. This row is load-bearing:
  `telemetry_test.exs:242-254` asserts the moduledoc table and `events/0`
  agree.
- `@type core_payload` (`:195-206`) gains `| DatamodelInit.t()`; its `@typedoc`
  "ten" becomes "eleven".
- `@effect_kinds` (`:230-241`) gains `:datamodel_init`.
- one `core_shape/2` clause:

  ```elixir
  # `location: nil` as a literal, not a `location/2` call: this payload names
  # no document node, so there is no index to resolve. The key is present
  # because ADR-0040's core family always carries it.
  defp core_shape(_machine, %DatamodelInit{} = init) do
    {%{macrostep: init.macrostep, microstep: init.microstep},
     %{location: nil, datamodel: init.datamodel}}
  end
  ```

- `events/0`'s doc comment (`:262-267` region) - the effect-name count moves
  from 10 to 11 and the total from 26 to 27.

#### 7. ADR-0040 amendment

**File**: `docs/adr/0040-session-telemetry-event-contract.md`
**Changes**: in the Core effect events section (`:348-377`), the "(10)"
heading becomes (11) and the `kind in [...]` list gains `:datamodel_init`; the
Metadata bullet gains a clause for it (`datamodel` - the starting map, which
fits no existing family's identities, exactly as `:datamodel_change`'s clause
was added by the st-oef3 amendment). Plus a dated
`**Amendment (st-1xwh):**` paragraph in the same form as the three existing
ones, stating that this event carries `location: nil` under the core family's
key-always-present rule because it names no document node - which is the
existing rule applied, not a carve-out - and that the status line at the top
of the document gains the amendment the way the previous three did.

#### 8. Changelog fragment

**File**: `changelog.d/st-1xwh.md` (new)
**Changes**: a user-facing entry - a new public effect and a new telemetry
event name are both public surface. Phases 2 and 3 extend this same fragment
rather than adding a second file (`changelog.d/README.md`: one fragment per
issue).

#### 9. Test fixtures and tests

**File**: `test/statifier/effect_test.exs`
**Changes**: a `{:datamodel_init, %DatamodelInit{...}}` tuple in
`@core_effects` (`:27-110`); the count assertion at `:132-134` moves `19 -> 20`
and its test name text from "nineteen" to "twenty". The two `for` generators
pick the new fixture up automatically.

**File**: `test/statifier/session/effects_test.exs`
**Changes**: one `@vocabulary` fixture row expecting
`[{:notify, {:datamodel_init, payload}}]`; the count assertion at `:326-328`
moves `22 -> 23` and the test name from "twenty-two fixtures across the
nineteen-tag vocabulary" to "twenty-three fixtures across the twenty-tag
vocabulary"; the tag-count comment near `:27-31` moves to twenty/eleven/nine.

**File**: `test/statifier/session/telemetry_test.exs`
**Changes**: the `length(events) == 26` assertion at `:225-235` moves to 27,
and its sabotage comment updates to name the new count.

**File**: `test/statifier/interpreter/datamodel_test.exs`
**Changes**: this file calls `Datamodel.initialize/1` about a dozen times in
the pipe form `machine |> MachineState.new() |> Datamodel.initialize()`
(`:44`, `:67`, `:100`, `:121`, `:142`, `:167`, `:191`, `:215`, `:237`, `:262`,
`:287`, `:362`, and any added since). Every one becomes
`{ms, _effects} = ...`, which breaks the pipe and is a mechanical edit, not a
rewrite of what each test asserts. New tests assert the baseline effect's
contents:
(a) a chart with no `<datamodel>` still emits exactly one `:datamodel_init`
whose map holds the four system variables (decision 2);
(b) every declared id appears with `:undefined` and **no** bound value, under
`binding="early"` - i.e. the baseline is genuinely pre-binding (decision 1);
(c) an author `:datamodel` option's keys and values appear verbatim
(decision 4);
(d) `macrostep`/`microstep` are 1/1, the counters `initialize/2` has already
advanced.
Each gets a sabotage line, e.g.
`# sabotage: initialize/1 builds the baseline after the binding fold -> red`.

**Files**: `test/statifier/machine/content/send_test.exs:98`,
`test/statifier/machine/content/cancel_test.exs:50`
**Changes**: each has its own private `machine_state/2` helper ending
`m |> MachineState.new(opts) |> Datamodel.initialize()` and returning the
result as a bare `%MachineState{}` that its callers then use directly. Both
become `{ms, _effects} = ...; ms`. **These are the two call sites dialyzer
will not catch** - it does not analyze `test/` - so they are named here
explicitly rather than left to a red full-suite run to discover. Grep
`Datamodel.initialize` across `test/` before declaring this item done; three
other test files mention the function only in comments
(`test/statifier/interpreter_test.exs:149`,
`test/statifier/interpreter/datamodel_write_location_test.exs:34`,
`test/statifier/machine/content/assign_test.exs:40`,
`test/statifier/machine/content/script_test.exs:39`) and need no change.

**File**: `test/statifier/interpreter_test.exs`
**Changes**: one test asserting the `:datamodel_init` effect is **first** in
`initialize/2`'s returned list, ahead of any global-`<script>` effect - the
ordering "The Appendix D rule" section fixes.
`# sabotage: initialize/2 appends datamodel_effects last -> red`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (use `mix quality --profile loop` between
      edits; a loop run alone never satisfies this phase).
- [x] `mix test test/statifier/effect_test.exs test/statifier/session/effects_test.exs test/statifier/session/telemetry_test.exs` passes - these three are the exhaustiveness proof.
- [x] `mix test test/statifier/interpreter/datamodel_test.exs` passes.
- [x] `Statifier.Session.Telemetry.events/0` returns 27 names, asserted by the
      updated test.
- [x] `mix adr.check` passes with the ADR-0040 amendment in place.
- [x] Dialyzer is clean, which proves the one **production** caller
      (`lib/statifier/interpreter.ex:249`) was updated - the widened `@spec`
      makes a missed bare-`MachineState` match a typing violation. It proves
      nothing about `test/`, which dialyzer does not analyze; the three test
      files named above are what a full `mix test` covers, and they are listed
      rather than left to a red suite to find.
- [x] `mix test.regression` shows no ratchet movement, and
      `test/passing_tests.json` is byte-identical: this phase adds an effect to
      a path that already ran and changes no SCXML semantics.
- [x] `mix quality --format json --report -` is available if a later agent
      needs to route on results.

#### Manual Verification:
- [ ] The touched functions still match the W3C spec prose they port (5.3.2 /
      5.3.3 / B.2.2) and the Appendix D call-site ordering at `:101-102`; no
      pseudocode body is involved, per "The Appendix D rule" above.
- [ ] The rewritten `initialize/1` `@doc` no longer predicts a trace row, and
      states the core-effect reason instead.
- [ ] The moduledoc table in `effect.ex`, the `@type core` union,
      `plan_one/2`, `@effect_kinds`, `core_shape/2`, the telemetry moduledoc
      table, and both fixture tables all name exactly the same eleven core
      tags - read them side by side once.
- [ ] The ADR-0040 amendment reads as an amendment in that document's
      established voice, not as a re-argument of the settled location rule.
- [ ] No regressions in existing telemetry subscribers.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: `d_index` becomes an identity, and every `<data>` binding emits

### Overview

`DatamodelChange` gains a nil-able `d_index`; `bind_value/4` emits one per
successful binding; `enter_state/2` grows a return value so late binding can
reach the stream; the observability vocabulary admits the identity.

### Changes Required:

#### 1. The identity, documented

**File**: `docs/observability.md`
**Changes**: constraint 3 (`:94-115`) names `d_index` as the third
compiler-assigned document-order index, alongside `t_index` and `c_index`,
resolved through `Statifier.Machine.data/2` to a `%Statifier.Machine.Data{}`
carrying its own `location` and `value_location`. The seams table row at
`:190` gains it. The prose says this completes an enumeration the compiler had
already outgrown (`lib/statifier/compiler.ex:497-517`,
`lib/statifier/machine/data.ex:4-5` already cite ADR-0012 item 3 for it), in
the same voice constraint 2's "the last two rows postdate the table above
them" note (`:72-78`) uses.

**File**: `docs/adr/0012-debuggability-designed-into-the-core.md`
**Changes**: a dated `**Amendment (st-1xwh):**` paragraph naming `d_index` as
a third identity under item 3, in the form ADR-0040 carries three of. Item 3's
original two-index sentence is left standing and the amendment explains it
rather than editing it, which is how the ADR-0040 amendments read. The status
line at `:3` gains the amendment in ADR-0040's exact spelling - today it reads
`Status: accepted (2026-08-04)` with no amendments, and ADR-0040's
`Status: accepted (2026-08-16) - amended 2026-08-16 (st-oef3: ...)` is the
form to copy.

#### 2. `d_index` on the payload

**File**: `lib/statifier/effect/datamodel_change.ex`
**Changes**: a `d_index` field (nil-able, not in `@enforce_keys`, matching
`c_index`'s treatment) and its `@type` entry
`d_index: non_neg_integer() | nil`. The moduledoc gains a paragraph recording
decision 3: `d_index` and `c_index` are mutually exclusive identities on this
payload; a non-nil `d_index` means the write was a `<data>` binding, which
belongs to no content block and therefore carries `owner: nil`; and a
`<data>` element is not executable content, so `Machine.content/2` could never
resolve it - `Machine.data/2` is its resolver.

#### 3. `Telemetry`, ordered ahead of the `c_index` clauses

**File**: `lib/statifier/session/telemetry.ex`
**Changes**: `core_shape/2`'s `%DatamodelChange{}` clause (`:553-568`) adds
`d_index: change.d_index` to its metadata, and its existing comment at
`:553-556` - which currently says no `location/2` clause is needed - is
corrected, because one now is. The resolver's own comment at `:624-629`, which
reads "whichever of `c_index`/`state_index`/`t_index` `payload` carries", is
corrected in the same edit to name four fields and to state the ordering
constraint below. Add, **above** the `c_index` clauses at `:632-641`:

```elixir
  # Must precede the `c_index` clauses: `%DatamodelChange{}` carries both
  # fields and the resolver dispatches on field name in clause order, so a
  # `c_index` clause placed first would match a binding's payload and answer
  # `nil` for every `<data>`. The guard, rather than a `%{d_index: nil}`
  # clause, is what lets a write's payload (`d_index: nil`) fall through to
  # the `c_index` clauses below.
  defp location(machine, %{d_index: d_index}) when is_integer(d_index),
    do: Machine.data(machine, d_index).location
```

The moduledoc table's `:datamodel_change` row (`:136-149`) gains `d_index` to
its metadata list.

**File**: `docs/adr/0040-session-telemetry-event-contract.md`
**Changes**: `:datamodel_change`'s metadata clause (`:363-366`) gains
`d_index`, and the location-resolution rule (`:132-156`) gains
`Statifier.Machine.data/2` as a fourth resolver alongside `content/2`,
`at/2`, and `transition/2`. Fold this into the Phase 1 `**Amendment
(st-1xwh):**` paragraph rather than opening a second one - it is one bead.

#### 4. Emission in `bind_value/4`

**File**: `lib/statifier/interpreter/datamodel.ex`
**Changes**: `bind_value/4`'s three clauses return `{MachineState.t(),
[Effect.t()]}`. The two failure clauses (`{:invalid, _}` and `{:src, _}`) and
the `{:error, reason}` branch of the third return `{machine_state, []}` -
decision 5, with a comment citing it. The success branch reads the prior value
before writing and builds the effect:

```elixir
  defp bind_value(machine_state, context, d_index, %{id: id} = data) do
    case Evaluator.evaluate(context, data.value) do
      {:ok, value} ->
        # A binding writes at the root key, so the prior value is one
        # `Map.get/3` - no `read_path/2` walk is needed, and `:undefined` is
        # ADR-0037's spelling for the seed `seed/2` wrote. Under
        # `binding="late"` this is not always the seed: an `<assign>` may have
        # written the id before the containing state was first entered.
        prior_value = Map.get(machine_state.datamodel, id, :undefined)

        {%{machine_state | datamodel: Map.put(machine_state.datamodel, id, value)},
         [
           {:datamodel_change,
            %Effect.DatamodelChange{
              location_path: [id],
              location_source: id,
              new_value: value,
              prior_value: prior_value,
              d_index: d_index,
              c_index: nil,
              owner: nil,
              macrostep: machine_state.macrostep,
              microstep: machine_state.microstep
            }}
         ]}

      {:error, reason} ->
        {raise_binding_error(machine_state, d_index, reason), []}
    end
  end
```

`location_source` is the `<data>`'s `id` - the author-written string that
names the location - which is the same discipline st-oef3 decision 7 applied
to `<assign>`'s raw `location` attribute.

`bind/6`'s environment-skip branch (`:341-345`) returns `{machine_state, []}`,
decision 5's other half.

#### 5. Both binding folds accumulate

**File**: `lib/statifier/interpreter/datamodel.ex`
**Changes**: `initialize/1`'s `Enum.reduce/3` over `d_indexes` (`:297-299`)
accumulates `{machine_state, effects}` and returns
`{machine_state, [init_effect | binding_effects]}` - the baseline first, then
the bindings in ascending `d_index` order, which is the order the existing
fold already runs in and which B.2.2 licenses (`datamodel.ex:286-294`).

`enter_state/2`'s `@spec` becomes
`(MachineState.t(), non_neg_integer()) -> {MachineState.t(), [Effect.t()]}`,
and `bind_state_data/4`'s three no-op clauses (`:444`, `:449`, `:453-454`)
return `{machine_state, []}`. Its `@doc` (`:369-424`) is updated where it says
"returning `machine_state` unchanged with no allocation".

#### 6. `ExitEntry.arrive/3` threads them

**File**: `lib/statifier/interpreter/exit_entry.ex`
**Changes**: the `if first_entry?` expression at `:732-735` yields
`{machine_state, data_effects}` in both branches (`{machine_state, []}` on the
else branch), and the final concatenation at `:744` becomes
`data_effects ++ onentry_effects ++ default_entry_effects ++ completion_effects`.
A comment cites `appendix-d.txt:311-313` and spec 5.3.3's "before any
`<onentry>` markup" for the leading position - see "The Appendix D rule". The
`first_entry?` capture at `:725` and the `entered_states` write at `:729` do
not move; the existing comment at `:717-724` explaining why is untouched.

#### 7. `Statifier.Effect` moduledoc

**File**: `lib/statifier/effect.ex`
**Changes**: the `:datamodel_change` row's "Produced by" cell (`:35`) gains
`Statifier.Interpreter.Datamodel.bind_value/4` (reached from both
`initialize/1` and `enter_state/2`) as a fifth producer.

#### 8. Tests

**File**: `test/statifier/interpreter/datamodel_test.exs`
**Changes**: tests asserting the binding effect, each with a sabotage line:
(a) `binding="early"`, top-level `<data expr="1">` - one `:datamodel_change`
with `d_index` set, `c_index: nil`, `owner: nil`, `location_path: ["x"]`,
`prior_value: :undefined`;
(b) `binding="early"`, a state-scoped `<data>` - also bound at `initialize/1`,
also emitted;
(c) `binding="late"` - only the top-level `<data>`'s effect appears from
`initialize/1`, and the state-scoped one does not;
(d) an environment-overridden top-level `<data>` emits **no** effect
(decision 5);
(e) a `{:invalid, _}` value, a `{:src, _}` value, and an evaluation failure
each emit no effect while still raising `error.execution` (decision 5);
(f) the effects arrive in ascending `d_index` order, after the baseline.

**File**: `test/statifier/interpreter/datamodel_test.exs`
**Changes**: the four existing direct `Datamodel.enter_state/2` call sites
(`:393`, `:421`, `:450`, and the identity assertion
`assert Datamodel.enter_state(ms, 0) == ms` at `:501`) destructure the pair;
`:501` becomes `assert Datamodel.enter_state(ms, 0) == {ms, []}`, which is the
same no-op claim in the new shape. Dialyzer will not flag these - it does not
analyze `test/` - so, as in Phase 1, they are named rather than left to the
suite. Then: a state-scoped `<data>` under `binding="late"` emits its
`:datamodel_change` when the state is first entered and **not** on a
re-entry - the `first_entry?` gate is unchanged and the test proves the effect
inherits it. That gate lives in `ExitEntry.arrive/3`, not in
`Datamodel.enter_state/2`, so this pair of tests drives a whole chart through
`Interpreter.initialize/2` + `handle_event/2` rather than calling
`enter_state/2` directly - a direct call would bypass the very gate under
test. Plus a test that an `<assign>` writing the id before first entry makes
the binding's `prior_value` the assigned value rather than `:undefined`.
`# sabotage: arrive/3 drops data_effects from the concatenation -> red`.

**File**: `test/statifier/effect_test.exs`
**Changes**: the `:datamodel_change` fixture gains a `d_index` key. No count
changes in this phase - the vocabulary size is unchanged.

**File**: `test/statifier/session/telemetry_test.exs`
**Changes**: a test that a `%DatamodelChange{}` with a non-nil `d_index`
resolves `metadata.location` through `Machine.data/2`, and one with
`d_index: nil, c_index: <n>` still resolves through `Machine.content/2` - the
clause-ordering hazard, asserted rather than assumed.
`# sabotage: the d_index location/2 clause is placed below the c_index clauses -> red`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits).
- [x] `mix test test/statifier/interpreter/ test/statifier/session/telemetry_test.exs` passes.
- [x] `mix adr.check` passes with the ADR-0012 amendment and the extended
      ADR-0040 amendment in place.
- [x] Dialyzer clean - the widened `enter_state/2` and `bind_value/4` specs
      make a missed caller a typing violation, which is what proves
      `ExitEntry.arrive/3` was updated.
- [x] `mix test.regression` is green and `test/passing_tests.json` is
      byte-identical; `mix test --include scion --include scxml_w3` shows no
      new failures. Emission changes no SCXML semantics, so no movement is the
      expected result; movement is a finding to report, not to ratchet away
      silently.
- [x] Doctor's 100% thresholds still met (`.doctor.exs`).
- [x] `mix quality --format json --report -` is available if a later agent
      needs to route on results.

#### Manual Verification:
- [ ] The touched functions still match the W3C spec text they port - 5.3.2
      (environment override), 5.3.3 (early/late binding and "before any
      `<onentry>` markup"), B.2.2 (no ordering dependencies) - line for line,
      with no control-flow change beyond the added return value, and the
      Appendix D call-site ordering at `:311-313` preserved.
- [ ] `d_index`'s admission reads as completing an enumeration the compiler
      had already outgrown, not as minting a new identity kind, in both
      `docs/observability.md` and the ADR-0012 amendment.
- [ ] The `location/2` clause ordering is correct by reading, not only by the
      test: a `%DatamodelChange{}` with a `d_index` must not reach the
      `c_index` clauses.
- [ ] No regressions in early/late binding behavior, the environment-override
      skip, or the `error.execution` raised by a failed binding.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically, and Manual Verification items are deferred to the end.

---

## Phase 3: Reconstruction from the stream alone

### Overview

The bead's acceptance criterion. The reconstruction test stops writing its
starting map as a literal and takes it from the stream, and late binding and
an environment-supplied `:datamodel` are covered.

### Changes Required:

#### 1. The existing reconstruction test loses its literal

**File**: `test/statifier/session/datamodel_reconstruction_test.exs`
**Changes**: delete `@starting_datamodel` (`:52`) and the comment above it
(`:43-51`) that names st-oef3 decision 6's gap. `collect_datamodel_changes/2`
(`:77-84`) becomes a collector for both tags, and `reconstruct/2` seeds its
fold from the `{:datamodel_init, _}` effect's `datamodel` instead of a
literal. The test asserts:

1. exactly one `:datamodel_init` effect arrives, and it arrives **before**
   every `:datamodel_change`;
2. the reconstruction - baseline, then every `:datamodel_change` applied at
   `location_path` - equals an expected literal map, with **no**
   `Session.snapshot/1` call and no `%Machine{}` handle anywhere in the fold;
3. separately labeled, the reconstruction equals `Session.snapshot/1`'s
   `datamodel` at every key but `"_event"` - written as
   `Map.delete(snapshot.datamodel, "_event")` rather than as the
   `Map.take/2` down to the author's three keys that `:119-131` does today.
   The narrowing shrinks from "the keys the test happens to know about" to
   "the one key decision 8 excludes", and a comment names decision 8 as the
   reason. `_sessionid`, `_name`, and `_ioprocessors` are all on the stream
   now via the baseline, so they are inside the comparison.

`apply_path/3` (`:58-69`) is unchanged: it already avoids
`Predicator.ContextLocation.put/3` deliberately, to prove a consumer with no
predicator dependency can apply the stream.

The file's leading comment (`:1-9`) is rewritten: the gap it documents is
closed, and it now states the stronger criterion - the datamodel comes from
the effect stream and nothing else.

`# sabotage: initialize/1 emits the baseline after the binding fold -> red`
(the reconstruction double-applies and the system variables go missing).

#### 2. New coverage the closed gap makes possible

**File**: `test/statifier/session/datamodel_reconstruction_test.exs`
**Changes**: three more tests in the same file, each with its own sabotage
line:

- **Late binding.** A `binding="late"` chart with a state-scoped `<data>` in a
  state entered by a transition after the initial configuration. The
  reconstruction is checked twice: once after initialization (the state's
  `<data>` is `:undefined`) and once after the event that enters it (the
  binding effect has arrived and the value is bound). This is the case a
  single init-time snapshot could not have covered - decision 1's argument,
  asserted.
- **Environment `:datamodel`.** A session started with a `:datamodel` option
  whose keys include one that shadows a top-level `<data>` and one that does
  not. The reconstruction reproduces both from the baseline effect alone, and
  the shadowed `<data>` contributes **no** `:datamodel_change` (decision 5).
- **`trace: false`.** The same chart as test 1 with tracing off; the
  reconstruction is identical. Both effects are core, and this is the
  assertion that keeps them so.

#### 3. Documentation

**File**: `docs/datamodel.md`
**Changes**: a short paragraph, beside the existing `<datamodel>`/`<data>`
line (`:22-23`), stating that the starting datamodel is on the effect stream:
one `:datamodel_init` baseline plus one `:datamodel_change` per binding, so
the datamodel is reconstructable from effects alone under both bindings.

**File**: `changelog.d/st-1xwh.md`
**Changes**: extend the Phase 1 fragment to state the whole user-facing
capability now that it is true.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits).
- [x] `mix test test/statifier/session/datamodel_reconstruction_test.exs`
      passes - the bead's acceptance criterion, with all four tests.
- [x] `grep -c "Session.snapshot" test/statifier/session/datamodel_reconstruction_test.exs`
      finds it only inside the separately labeled oracle test, and
      `grep "@starting_datamodel"` finds nothing.
- [x] `mix test.regression` is green and `test/passing_tests.json` is
      byte-identical.
- [x] `mix quality --format json --report -` is available if a later agent
      needs to route on results.

#### Manual Verification:
- [ ] The reconstruction genuinely uses no other channel: read the fold and
      confirm it touches only effect payload fields, no `%Machine{}`, no
      `%MachineState{}`.
- [ ] The late-binding test would have failed against an init-time-snapshot-only
      design - i.e. it is testing decision 1's actual load-bearing case, not a
      restatement of test 1.
- [ ] `docs/datamodel.md`'s new paragraph is accurate about both bindings and
      does not overclaim a wire format (`docs/observability.md:173-179`).
- [ ] No regressions in `<assign>`, `<send idlocation>`, `<invoke idlocation>`,
      or `<finalize>` emission from st-oef3.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are surfaced at the end.

---

## Corpus/Ratchet Notes

No corpus regeneration. This plan changes no SCXML semantics - it adds effects
to paths that already ran and grows two return types - so
`test/passing_tests.json` is expected to be byte-identical after every phase.
If any phase moves a conformance result, that is evidence of an unintended
behavior change (the most likely culprit being the `arrive/3` concatenation
order in Phase 2) and is a finding to investigate, not a baseline to add.

## Performance Considerations

Per session, once: one `%DatamodelInit{}` struct holding a *reference* to the
datamodel map. Elixir maps are immutable, so this is one word, not a copy of
the datamodel - decision 6.

Per successfully bound `<data>`, once: one `Map.get/3` for `prior_value` and
one `%DatamodelChange{}` struct. Both are the same order as the `Map.put/3`
already on that path, and the count is bounded by the number of `<data>`
elements in the document - it is not a per-microstep or per-configuration
cost. Nothing here walks the datamodel, the configuration, or the machine.

`enter_state/2` loses its "returns `machine_state` unchanged with no
allocation" property on the `binding="early"` path, which now allocates one
two-tuple with an empty list per state entry. `arrive/3` already allocates
three effect lists and a tuple per entry, so this is within the noise of what
that function already does.

## Testing Strategy

### Unit Tests:
- `test/statifier/interpreter/datamodel_test.exs` - the baseline effect's
  contents (no-`<datamodel>` chart, pre-binding values, environment option,
  counters) and the binding effect's contents and identity fields, across
  early/late, top-level/state-scoped, skipped, and all three failure shapes.
- `test/statifier/effect_test.exs` /
  `test/statifier/session/effects_test.exs` /
  `test/statifier/session/telemetry_test.exs` - the vocabulary's
  exhaustiveness, by their existing table-driven construction, plus the
  `location/2` clause-ordering test Phase 2 adds.
- The existing late-binding entry tests - the `first_entry?` gate now governs
  an effect as well as a write.
- `test/statifier/session/datamodel_reconstruction_test.exs` - the acceptance
  test and its three siblings.

Key edge cases: a chart with no `<datamodel>` at all; an environment
`:datamodel` key that shadows a top-level `<data>` (baseline carries it, no
binding effect); a `<data>` whose value fails to compile, whose value is
`src`, and whose expression fails at runtime (no effect, `error.execution`
unchanged); a late-bound state entered twice (one effect, on first entry
only); a late-bound id written by `<assign>` before its state is first entered
(`prior_value` is the assigned value, not `:undefined`); a chart that
processes at least one event, so `"_event"` genuinely diverges between the
reconstruction and the snapshot and decision 8's exclusion is exercised rather
than vacuous.

### Manual Testing Steps:
1. Start a `Statifier.Session` on a `binding="early"` chart with a couple of
   `<data>` elements and an `<assign>`, subscribe, and read the effects off the
   mailbox in order - confirm `:datamodel_init` arrives first, then one
   `:datamodel_change` per `<data>`, then the `<assign>`'s.
2. Attach a `:telemetry` handler to
   `[:statifier, :session, :effect, :datamodel_change]` and confirm
   `metadata.location` points at the `<data>` element's own span for a
   binding and at the `<assign>` node for a write.
3. Run a `binding="late"` chart and confirm the state-scoped `<data>`'s effect
   arrives at state entry, not at initialization.
4. Run the same chart with `trace: false` and confirm both effects still
   arrive - the point of keeping them core.

## Residual open questions

None affecting implementation. Two items are recorded rather than decided
because they belong to another repo or to a human:

- **The wire format** for the baseline `datamodel` map, and for `:undefined`
  inside it, is deliberately not decided here (decision 6, st-oef3 decision 8).
  `docs/observability.md:173-179` makes "no wire format" a non-goal for this
  repo, and per ADR-0025 the serialization is statifier-ui's own ADR-0005 half
  of the mirror. If that repo needs a specific spelling for `:undefined` or a
  canonical ordering for the map, it is their bead. The baseline map is the
  first payload in this vocabulary whose value is an open-ended map rather than
  a scalar or a list of indexes, so it is the most likely one to prompt that
  question over there.
- **The `mirrors: sui-t36.1` line on the bead is unrefreshed**, which the
  bead's own description already records: `sui-t36.1` was not resolvable from
  this tracker when the bead was filed. Per ADR-0025 the obligation to
  re-read the other tracker and write a dated note attaches to *scheduling,
  claiming, adding a dependency on, or citing the status of* a mirrored bead.
  Planning is none of those, so this plan does not act on the note - but the
  refresh is owed before the branch is published, and it is a human's call
  whether the statifier-ui half exists yet.

## References

- Source document: `docs/plans/260816-st-oef3-assign-datamodel-change-effect.md`
  (decision 6 is the gap this plan closes; its ten decisions are settled
  ground)
- Related ADRs: `docs/adr/0002-*` (Appendix D port obligation),
  `docs/adr/0003-*` (pure core with effects), `docs/adr/0012-*` and
  `docs/observability.md` (observability constraints - amended by this plan
  for `d_index`), `docs/adr/0024-*` (`<data src>` is never fetched),
  `docs/adr/0025-*` (cross-repo tracker authority), `docs/adr/0034-*` (replay
  re-drives the core), `docs/adr/0037-*` (`:undefined` at the writer),
  `docs/adr/0040-*` (session telemetry contract - amended by this plan)
- Similar implementation: `lib/statifier/effect/datamodel_change.ex` and
  `lib/statifier/interpreter/datamodel.ex:129-181` (st-oef3's write-side half,
  the precedent for identity, `prior_value`, and the no-effect-on-failure rule)
- Spec: 5.3.2 (environment override, failure clause), 5.3.3 (early/late
  binding), 5.10 (system variables), B.2.2 (no ordering dependencies);
  Appendix D `:101-102` and `:311-313` (the two call sites, no procedure body)
- Bead: st-1xwh (mirrors `sui-t36.1`)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions still match the W3C spec prose they port (5.3.2 /
      5.3.3 / B.2.2) and the Appendix D call-site ordering at `:101-102`; no
      pseudocode body is involved, per "The Appendix D rule" above.
- [ ] The rewritten `initialize/1` `@doc` no longer predicts a trace row, and
      states the core-effect reason instead.
- [ ] The moduledoc table in `effect.ex`, the `@type core` union,
      `plan_one/2`, `@effect_kinds`, `core_shape/2`, the telemetry moduledoc
      table, and both fixture tables all name exactly the same eleven core
      tags - read them side by side once.
- [ ] The ADR-0040 amendment reads as an amendment in that document's
      established voice, not as a re-argument of the settled location rule.
- [ ] No regressions in existing telemetry subscribers.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] The touched functions still match the W3C spec text they port - 5.3.2
      (environment override), 5.3.3 (early/late binding and "before any
      `<onentry>` markup"), B.2.2 (no ordering dependencies) - line for line,
      with no control-flow change beyond the added return value, and the
      Appendix D call-site ordering at `:311-313` preserved.
- [ ] `d_index`'s admission reads as completing an enumeration the compiler
      had already outgrown, not as minting a new identity kind, in both
      `docs/observability.md` and the ADR-0012 amendment.
- [ ] The `location/2` clause ordering is correct by reading, not only by the
      test: a `%DatamodelChange{}` with a `d_index` must not reach the
      `c_index` clauses.
- [ ] No regressions in early/late binding behavior, the environment-override
      skip, or the `error.execution` raised by a failed binding.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically, and Manual Verification items are deferred to the end.

---

### Phase 3

- [ ] The reconstruction genuinely uses no other channel: read the fold and
      confirm it touches only effect payload fields, no `%Machine{}`, no
      `%MachineState{}`.
- [ ] The late-binding test would have failed against an init-time-snapshot-only
      design - i.e. it is testing decision 1's actual load-bearing case, not a
      restatement of test 1.
- [ ] `docs/datamodel.md`'s new paragraph is accurate about both bindings and
      does not overclaim a wire format (`docs/observability.md:173-179`).
- [ ] No regressions in `<assign>`, `<send idlocation>`, `<invoke idlocation>`,
      or `<finalize>` emission from st-oef3.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are surfaced at the end.

---
