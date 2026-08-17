---
date: 2026-08-16
planner: Claude
git_commit: 8015033ab029fb81788a2f55b8d014e201cdd03b
branch: st-oef3-assign-datamodel-effect
repository: statifier-ex
beads_issue: st-oef3
topic: "A core :datamodel_change effect emitted at every datamodel write"
tags: [plan, datamodel, effects, observability]
status: ready
last_updated: 2026-08-16
last_updated_by: Claude
---

# Datamodel-change effect for `<assign>` Implementation Plan

## Overview

Add one new **core** effect - `{:datamodel_change,
%Statifier.Effect.DatamodelChange{}}` - emitted at every successful datamodel
write, carrying the resolved location path, the new value, the prior value,
and a constraint-3 identity, so a consumer can apply the effect stream to a
starting map and arrive at the datamodel without ever calling
`Session.snapshot/1`. Bead: st-oef3 (mirrors `sui-t36.1`).

The research document
`docs/research/260816-st-oef3-assign-datamodel-change-effect.md` is the
foundation; it left ten open questions. Every one is decided below, on the
record, under "Decisions".

## Current State Analysis

- `Statifier.Machine.Content.Assign`'s `execute/2` returns `{:ok, context, []}`
  unconditionally (`lib/statifier/machine/content/assign.ex:79-90`). `c_index`
  is in scope and unused. The only stream evidence an `<assign>` ran is the
  block-level `Trace.ContentExecuted`, which carries a *list* of `c_indexes`
  and no values.
- `Statifier.Interpreter.Datamodel.write_location/4`
  (`lib/statifier/interpreter/datamodel.ex:121-138`) holds the whole write:
  it is the **only** place the resolved path exists, and the only place where
  both the pre-write and post-write datamodel are in hand. It returns
  `{:ok, machine_state, datamodel_context}` and discards both.
- It has four callers:

  | # | Call site | Identity in scope | Effects returned today |
  |---|---|---|---|
  | 1 | `lib/statifier/machine/content/assign.ex:82` | `node.c_index`, `context.owner` | `[]` |
  | 2 | `lib/statifier/interpreter.ex:785` (empty-`<finalize>` auto-assign) | `state_index`, `invoke_index` | none; caller hardcodes `[]` |
  | 3 | `lib/statifier/machine/content/send.ex:267` (`<send idlocation>`) | `node.c_index`, `owner`, `send_id` | `[{:send, _}]` / `[{:send_delayed, _}]` |
  | 4 | `lib/statifier/interpreter.ex:1469` (`<invoke idlocation>`) | `state_index`, `invoke_index`, `invoke_id` | `[{:invoke, _}]` |

- `Predicator.ContextLocation` exposes `put/3` and `resolve/2`
  (`deps/predicator/lib/predicator/context_location.ex:210`, `:126`) but **no
  path getter**. Reading a prior value at a resolved path needs a local walk.
- The vocabulary is enumerated exhaustively in eight places, none with a
  catch-all (see Phase 2's change list). `Session.Telemetry.core_shape/2`
  raises `FunctionClauseError` on an unknown payload
  (`lib/statifier/session/telemetry.ex:428`), which is the design.
- `Session.Telemetry`'s single-index resolver `location/2`
  (`lib/statifier/session/telemetry.ex:598-614`) dispatches on the *field
  name* `c_index`/`state_index`/`t_index`, not on the struct type. A payload
  carrying `c_index` gets `metadata.location` with **no new clause**, and a
  `nil` `c_index` resolves to `nil` - exactly `Effect.Log`'s behavior for a
  global `<script>`.
- The initial datamodel is not on the stream at all:
  `Datamodel.initialize/1` returns a bare `MachineState.t()` with the omission
  reasoned in its own `@doc` (`lib/statifier/interpreter/datamodel.ex:221-232`),
  `enter_state/2` is equally silent, and `MachineState.new/2`'s `:datamodel`
  option plus `SystemVariables.initial/2` never announce themselves either.

## Desired End State

Every successful datamodel write in `lib/statifier/` puts one
`{:datamodel_change, %Effect.DatamodelChange{}}` on the effect list, in the
core's own order, unconditionally (not trace-gated). A test folds only those
effects over a starting map and asserts the resulting map equals the chart's
final datamodel, without calling `Session.snapshot/1` in the reconstruction.
`[:statifier, :session, :effect, :datamodel_change]` is a published telemetry
event, and `Telemetry.events/0` returns 26 names.

Verify with: `mix quality` green; the reconstruction test in
`test/statifier/session/datamodel_reconstruction_test.exs` passing;
`Telemetry.events/0 |> length() == 26`.

### Key Discoveries

- `write_location/4` is the single choke point for all four writes and the
  only holder of the resolved path (`lib/statifier/interpreter/datamodel.ex:128-137`).
- `Machine.Content.owner/0` (`lib/statifier/machine/content.ex:64-68`) already
  has a `{:finalize, state_index, invoke_index}` case, which is exactly call
  site 2's identity. Only call site 4 needs a widening, and
  `Trace.ContentExecuted` sets the precedent for widening at the payload
  rather than in `Machine.Content`.
- `Effect.Log` (`lib/statifier/effect/log.ex:23-33`) is the shape to model:
  `c_index` + `owner` + `macrostep`/`microstep`, built as a struct literal in
  the node, `c_index` nil-able.
- ADR-0040's st-ii9v amendment forbids a `location` key on any trace event and
  keeps resolved locations exclusively on single-index **core** effect events.
- ADR-0037 spells an unbound value `:undefined` at the writer.
- `docs/architecture.md:108-122` and `lib/statifier/interpreter/content.ex:50-56`:
  a new element is a node plus a defimpl, "never a change to the runner".
- ADR-0034: `Replay.perform_instruction/3` matches instruction shapes, not
  effect tags, so an effect that plans only to `{:notify, _}` needs no replay
  change.

## Decisions

The research's ten open questions, decided. These are the plan's contract;
the implementer does not re-open them.

**1. Core effect, not trace-gated.** Three reasons, in the order that carried
it. (a) The bead's criterion is reconstruction from the effect stream; a
trace-gated effect makes reconstruction possible only when `trace: true`, so
gating defeats the feature rather than optimizing it. (b)
`docs/observability.md:57-78`'s row-admission test for constraint 2 is "a
phase boundary Appendix D itself names" - the precedent `InvokePass` and
`FinalizeAutoforward` set. A datamodel write is not a phase boundary; it sits
*inside* the existing "content executed" row. (c) ADR-0040's st-ii9v amendment
keeps resolved locations exclusively on single-index core effect events - a
trace member could not carry the location data this payload is for. Cost is
one struct literal on a path that already does a predicator resolve and a map
write, the same trade `Effect.Log` already makes unconditionally.

**2. All four call sites emit.** Consistency is not the argument; the
acceptance criterion is. A reconstruction that silently diverges whenever a
chart uses `<send idlocation>`, `<invoke idlocation>`, or an empty
`<finalize>` is not a reconstruction. Once Phase 1 makes `write_location/4`
report what it wrote, the incremental cost per site is one struct literal.

**3. Identity without a `c_index`.** The payload carries `c_index`
(`nil`-able) and `owner`, exactly as `Effect.Log` does, and widens `owner/0`
in its own typedoc rather than in `Machine.Content` - the precedent
`Trace.ContentExecuted` set for `{:global_script, index}`. Per site: 1 and 3
carry their real `c_index` and `owner`; 2 carries `c_index: nil` and
`owner: {:finalize, state_index, invoke_index}`, which
`Machine.Content.owner/0` already has; 4 carries `c_index: nil` and
`owner: {:invoke, state_index, invoke_index}`, the one new case, declared in
`DatamodelChange`'s own `owner/0`. This fits ADR-0040 with no telemetry
change: `location/2` resolves a real `c_index` through `Machine.content/2`
and yields `nil` for the two runner sites.

**4. Prior value: captured, in `write_location/4`, at the full path.** It is
the only place holding both the resolved path and the pre-write datamodel
(`datamodel.ex:128-137`); resolving a second time at the caller would double
the resolution cost on the hottest datamodel path. It is the value at the
**full path**, not the whole prior root - a root copy is O(root size) per
write and is redundant with the path. "No prior value" spells `:undefined`,
per ADR-0037's single spelling for an unbound value. This does conflate "the
path was absent" with "the path held `:undefined`", and that is accepted:
`prior_value` exists for diffing and undo in an inspector, never for
reconstruction, which only ever applies `new_value` at `location_path`.
Because `Predicator.ContextLocation` has no getter, the read is a private
`read_path/2` in `Statifier.Interpreter.Datamodel`: a `reduce_while` over the
path segments, `Map.fetch/2` for a binary key and `Enum.fetch/2` for an
integer index, `:undefined` on any miss.

**5. Emission lives at the call sites; the mechanics module reports facts.**
`write_location/4` gains a fourth return element - a `%Datamodel.Write{}`
record of `path`, `prior_value`, `new_value` - and builds no effect itself.
Each caller turns that record plus its own identity into the effect. This is
what keeps `content.ex:50-56` and `docs/architecture.md:108-122` intact
literally rather than by argument: the seam is still taken in the node, the
block runner is untouched, and `Interpreter.Datamodel` stays what its
moduledoc says it is - shared mechanics, not an emitter. The two runner sites
build the effect in the runner, where their writes, their `:invoke` effect,
and their platform-error handling already live; `architecture.md`'s rule
bounds what adding a new *element* may cost, and neither of those is an
element added here.

**6. The initial datamodel is out of scope.** Emitting for `<data>` binding
means changing `initialize/1` and `enter_state/2` to return
`{machine_state, [effect]}` (their `@doc` at `datamodel.ex:221-232` already
anticipates the day, and explicitly declines to invent the shape early), plus
the `:datamodel` environment seed and `SystemVariables.initial/2`, which live
in `MachineState.new/2` - outside the interpreter, before any effect list
exists. That is a second bead's surface, with its own identity question
(a `d_index`, not a `c_index`) and its own scoping question about system
variables. **This plan is scoped to writes.** A follow-up bead is warranted
for the initial-binding half; the orchestrator files it (see "Follow-up bead
to file"). **The remaining gap, stated plainly:** after this plan, a consumer
can reconstruct every *change* to the datamodel from the effect stream alone,
but must obtain the starting map by some other channel. The acceptance test
in Phase 3 therefore folds the effect stream over an explicitly written
starting map and never calls `Session.snapshot/1` in the reconstruction; a
separately labeled oracle assertion compares the result against the real
datamodel.

**7. `location_path` is predicator's resolved path; the raw string rides
alongside.** `location_path` is
`Predicator.ContextLocation.location_path()`, `[binary() | integer()]` - the
only shape a consumer can apply, and the only one that makes `items[i]`
reproducible, since the raw `"items[i]"` is unindexable without the
pre-assignment datamodel the consumer does not have. `location_source` is the
raw author string, already in hand at zero cost, and is what a human reads
and what the existing error messages quote. Both, under distinct names, so
neither is mistaken for the other - the same discipline
`Machine.Content.Assign`'s moduledoc applies to `location` vs `node_location`.

**8. No wire-format commitment.** `new_value` and `prior_value` are ordinary
predicator values or the atom `:undefined`. `docs/observability.md:175` lists
"no wire format" as an explicit non-goal for this repo, and per ADR-0025 the
serialization is statifier-ui's ADR-0005 half of the mirror. The payload
moduledoc says so, so the next reader does not invent one.

**9. A failed write emits nothing.** The datamodel did not change, so a
reconstruction has nothing to apply. The failure is already observable on
every site: `error.execution` with origin `{:content, c_index, owner}` at site
1 (`interpreter/content.ex:58-69`), `error.execution` with origin
`{:finalize, ...}` at site 2, a discarded `<send>` at site 3 (ADR-0036), an
aborted invocation at site 4 (ADR-0031). A second, differently shaped member
for an event the error channel already carries would grow the vocabulary
without adding information.

**10. No new row in `docs/observability.md`, and no new ADR.** That
document's constraint-2 table is the *trace* vocabulary, and per decision 1
this is a core effect, so the table does not apply. Adding a core member is a
bead-level decision here: `:cancel_invoke` and `:autoforward` joined without
ADRs of their own (`lib/statifier/effect.ex:113`). What does change is
**ADR-0040**, which its own text makes the authoritative reference for every
`[:statifier, :session, ...]` event: it gains one row for
`[:statifier, :session, :effect, :datamodel_change]`, in the form of a dated
amendment, the practice ADR-0040 already carries twice (st-f6i9, st-ii9v).

## What We're NOT Doing

- Not emitting for `<data>` binding, the `:datamodel` environment seed, or
  `SystemVariables.initial/2` (decision 6). A follow-up bead covers it.
- Not adding a trace-family member, and not touching
  `docs/observability.md`'s constraint-2 table (decisions 1 and 10).
- Not emitting on a failed write (decision 9).
- Not defining a serialization or wire format for the payload (decision 8).
- Not changing `Statifier.Replay`: an effect that plans only to
  `{:notify, _}` adds no instruction shape, and ADR-0034's no-catch-all fold
  is untouched.
- Not fixing `.claude/wurk/codebase.md`, which the research found stale (it
  says `<send>`/`<invoke>` are unimplemented and that `send_`/`inv_` are not
  yet search keys). Out of scope for this bead; it is reported separately so
  it can be filed on its own.
- Not carrying the whole prior root, and not adding a separate `:absent`
  spelling for a missing prior value (decision 4).

## Implementation Approach

Three phases, each independently committable and independently green.

Phase 1 is a pure-mechanics change with no behavior change: `write_location/4`
starts reporting what it wrote. It is gate-verifiable on its own through unit
tests on the new return shape.

Phase 2 adds the vocabulary member with nothing yet producing it. This is
genuinely self-verifying rather than dead structure: both table-driven fixture
tables (`effect_test.exs`, `session/effects_test.exs`) and the telemetry
moduledoc-vs-`events/0` consistency test exercise every member by
construction, so the phase's own gate proves it. This is the same shape
`:send`/`:send_delayed`/`:cancel` have carried for several beads while
unproduced.

Phase 3 wires emission at all four sites and lands the acceptance test.

### The Appendix D rule

No Appendix D pseudocode changes. `write_location/4` has no pseudocode body to
port - `Statifier.Interpreter.Datamodel`'s moduledoc records that
`initializeDatamodel`/`initializeDataModel` have no procedure body anywhere in
Appendix D, and the write mechanics come from spec prose 5.4.2 / 5.9.2 / 5.10,
not from a block. **This plan introduces no deviation from Appendix D.** The
two runner sites touched in Phase 3 (`write_finalize_target`,
`maybe_write_idlocation`) keep their existing control flow exactly; only their
return values grow.

---

## Phase 1: `write_location/4` reports the write

### Overview

`Statifier.Interpreter.Datamodel.write_location/4` returns a fourth element
describing the write it performed: the resolved path, the prior value, and the
new value. All four callers are updated to match and discard it. No behavior
changes, no effect exists yet.

### Changes Required:

#### 1. The write record

**File**: `lib/statifier/interpreter/datamodel.ex`
**Changes**: Add a nested `Statifier.Interpreter.Datamodel.Write` struct in
its own file, with a moduledoc stating it is a *report of a write that
happened*, never an instruction, and that `prior_value` spells a missing prior
`:undefined` per ADR-0037.

**File**: `lib/statifier/interpreter/datamodel/write.ex` (new)

```elixir
defmodule Statifier.Interpreter.Datamodel.Write do
  @moduledoc """
  What `Statifier.Interpreter.Datamodel.write_location/4` wrote ...
  """

  @enforce_keys [:path, :prior_value, :new_value]
  defstruct [:path, :prior_value, :new_value]

  @type t :: %__MODULE__{
          path: Predicator.ContextLocation.location_path(),
          prior_value: term(),
          new_value: term()
        }
end
```

#### 2. `write_location/4`'s return and the prior read

**File**: `lib/statifier/interpreter/datamodel.ex`
**Changes**: `@spec` becomes
`{:ok, MachineState.t(), Predicator.Context.t(), Write.t()} | {:error, term()}`.
The `with` body reads the prior value from the *pre-write*
`machine_state.datamodel` at the resolved `path` and builds the record. Add a
private `read_path/2`, since `Predicator.ContextLocation` has `put/3` but no
getter (`deps/predicator/lib/predicator/context_location.ex:210`).

```elixir
    with {:ok, path} <- resolve_location(path_source, datamodel_context),
         :ok <- check_system_variable(path),
         :ok <- check_root(machine_state, path_source, path),
         prior_value = read_path(machine_state.datamodel, path),
         {:ok, new_datamodel} <- write(machine_state, path_source, path, value) do
      ...
      {:ok, new_machine_state,
       Evaluator.bind(datamodel_context, root, Map.fetch!(new_datamodel, root)),
       %Write{path: path, prior_value: prior_value, new_value: value}}
    end
```

`read_path/2` is a `reduce_while` over the segments: `Map.fetch/2` on a binary
key, `Enum.fetch/2` on an integer index against a list, `:undefined` on any
miss or on a non-container. Its comment cites ADR-0037 for the `:undefined`
spelling and decision 4 above for "value at the full path, not the whole
root".

The prior read is placed *before* `write/4` deliberately - the comment says
so, since reading it after would see the value just written.

#### 3. The four callers

**Files**: `lib/statifier/machine/content/assign.ex:81`,
`lib/statifier/machine/content/send.ex:267`,
`lib/statifier/interpreter.ex:785`, `lib/statifier/interpreter.ex:1469`
**Changes**: match the 4-tuple and bind the record to `_write` in this phase.
The two `maybe_write_idlocation/4` `nil` clauses must return a 4-tuple too;
they return `{:ok, machine_state, datamodel_context, nil}` - `nil` meaning "no
write was attempted", distinct from a `%Write{}` meaning "a write happened".
Both `@spec`s widen to `Write.t() | nil`.

#### 4. Tests

**File**: `test/statifier/interpreter/datamodel_test.exs`
**Changes**: tests asserting the record's contents on (a) a fresh write over a
seeded-`:undefined` id (`prior_value == :undefined`), (b) an overwrite
(`prior_value` is the old value), (c) a deep path `a.b.c` (path is
`["a", "b", "c"]`, `prior_value` is the leaf's old value, not the root's),
(d) a bracket path `items[1]` (path contains the integer `1`), (e) vivified
intermediate containers (`prior_value == :undefined`, not a crash). Each gets
a sabotage line, e.g.
`# sabotage: read_path/2 returns nil instead of :undefined -> red`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (use `mix quality --profile loop` between
      edits; a loop run alone never satisfies this phase).
- [x] `mix test test/statifier/interpreter/datamodel_test.exs` passes.
- [x] Dialyzer is clean, which is what proves all four callers were updated -
      the widened `@spec` makes a missed 3-tuple match a typing violation.
- [x] `mix test.regression` shows no ratchet movement (this phase changes no
      observable behavior, so the conformance results must be identical).

#### Manual Verification:
- [ ] The touched functions still match the W3C spec prose they port (5.4.2 /
      5.9.2 / 5.10); no Appendix D pseudocode is involved, per "The Appendix D
      rule" above.
- [ ] `read_path/2`'s `:undefined` is genuinely indistinguishable from a
      stored `:undefined` and that is documented as accepted (decision 4), not
      silently glossed.
- [ ] No regressions in `<send idlocation>` / `<invoke idlocation>` /
      `<finalize>` behavior.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end.

---

## Phase 2: `:datamodel_change` joins the vocabulary

### Overview

Add the tenth core effect and every exhaustive enumeration it must appear in.
Nothing produces it yet; the table-driven fixtures are what verify it.

### Changes Required:

#### 1. The payload

**File**: `lib/statifier/effect/datamodel_change.ex` (new)
**Changes**: the struct, modeled on `Effect.Log`
(`lib/statifier/effect/log.ex:23-33`).

```elixir
  @typedoc "Which construct performed the write - `Machine.Content.owner/0` widened with the `<invoke idlocation>` case, which belongs to no content block (see `Trace.ContentExecuted`'s owner typedoc for the same widening-at-the-payload precedent)."
  @type owner :: Content.owner() | {:invoke, non_neg_integer(), non_neg_integer()}

  @enforce_keys [:location_path, :location_source, :new_value, :prior_value, :macrostep, :microstep]
  defstruct [
    :location_path,
    :location_source,
    :new_value,
    :prior_value,
    :c_index,
    :owner,
    :macrostep,
    :microstep
  ]
```

The moduledoc records decisions 4, 7, 8, and 9 by number and cites ADR-0037
for `:undefined` and `docs/observability.md:175` for the absence of a wire
format.

#### 2. `Statifier.Effect`

**File**: `lib/statifier/effect.ex`
**Changes**: a row in the moduledoc vocabulary table (`:24-43`) with the
"Produced by" cell reading "not yet produced" in this phase; a
`| {:datamodel_change, DatamodelChange.t()}` member in `@type core`
(`:114-123`); the `@typedoc` at `:113` changing "nine core effects" to "ten";
the alias; and the prose at `:45-48` naming what the interpreter produces
stays accurate (it is not produced yet).

#### 3. `Session.Effects`

**File**: `lib/statifier/session/effects.ex`
**Changes**: one `plan_one/2` clause beside `:log`'s at `:149`, planning to
nothing but its own notification:

```elixir
  defp plan_one({:datamodel_change, _change} = effect, _session_id), do: [{:notify, effect}]
```

Update the moduledoc sentence at `:108-109` ("`:log` and `:trace` effects plan
to nothing but their own `{:notify, effect}`") to include
`:datamodel_change`.

#### 4. `Session.Telemetry`

**File**: `lib/statifier/session/telemetry.ex`
**Changes**, each an exhaustive enumeration that must move together:
- the moduledoc "Core effect events (9)" table header and rows (`:130-142`) -
  header becomes (10), plus a row for
  `[:statifier, :session, :effect, :datamodel_change]`. This row is
  load-bearing: `telemetry_test.exs:253` asserts the moduledoc table and
  `events/0` agree.
- `@type core_payload` (`:187-197`) gains `| DatamodelChange.t()`; its
  `@typedoc` "nine" becomes "ten".
- `@effect_kinds` (`:221-231`) gains `:datamodel_change`.
- one `core_shape/2` clause, modeled on `Log`'s at `:538-541`:

  ```elixir
  defp core_shape(machine, %DatamodelChange{} = change) do
    {%{macrostep: change.macrostep, microstep: change.microstep},
     %{
       location: location(machine, change),
       location_path: change.location_path,
       location_source: change.location_source,
       new_value: change.new_value,
       prior_value: change.prior_value,
       c_index: change.c_index,
       owner: change.owner
     }}
  end
  ```

- **No `location/2` clause is needed**: the resolver at `:598-614` dispatches
  on the `c_index` field name and already handles `c_index: nil`. Add a
  one-line comment at the new `core_shape/2` clause saying so, so a later
  reader does not add a redundant clause.
- `events/0`'s doc comment (`:245-251`) - "the 9 ... effect names" becomes 10.
- No `effect/3` change: core kind comes from the tuple tag itself (`:427-435`).

#### 5. ADR-0040 amendment

**File**: `docs/adr/0040-session-telemetry-event-contract.md`
**Changes**: two edits, in the **Core effect events** section at `:341-356`.
Note there is no per-event markdown table for core effects - the lifecycle
table around `:329` is a different family, and editing it would be the wrong
place.

- `:341` - the heading "Core effect events (9), emitted regardless of
  `trace`" becomes (10); `:344`'s `kind in [...]` list gains
  `:datamodel_change`.
- `:349-356` - the Metadata bullet. `:datamodel_change`'s fields
  (`location_path`, `location_source`, `new_value`, `prior_value`) do **not**
  fit the existing "the family's identities" prose, which groups the send
  family, the invoke family, `:log`, and `:done`. It gets its own clause in
  that bullet rather than being appended to another family's. `location` needs
  no new prose: the existing "per the resolution rule above" already covers a
  single `c_index`, nil included.

Plus a dated `**Amendment (st-oef3):**` paragraph in the same form as the
existing st-f6i9 and st-ii9v amendments, stating that the event carries
`metadata.location` under the existing single-index rule when `c_index` is
non-nil and no location for the two runner-side writes - which is the rule
already, not a new carve-out.

#### 6. Changelog fragment

**File**: `changelog.d/st-oef3.md` (new)
**Changes**: a user-facing entry - a new public effect and a new telemetry
event name are both public surface.

#### 7. Test fixtures

**File**: `test/statifier/effect_test.exs`
**Changes**: a `{:datamodel_change, %DatamodelChange{...}}` tuple in
`@core_effects` (`:26-53`); the count assertion at `:120-124` moves
`18 -> 19` and its test name text from "eighteen" to "nineteen". The two `for`
generators pick the new fixture up automatically.

**File**: `test/statifier/session/effects_test.exs`
**Changes**: one `@vocabulary` fixture row expecting
`[{:notify, {:datamodel_change, payload}}]`; the count assertion at `:304-306`
moves `21 -> 22` and the test name from "twenty-one fixtures across the
eighteen-tag vocabulary" to "twenty-two fixtures across the nineteen-tag
vocabulary"; the comment at `:27-31` updates "eighteen tags: nine core plus
nine trace" to nineteen/ten/nine.

**File**: `test/statifier/session/telemetry_test.exs`
**Changes**: the `length(events) == 25` assertion at `:223-228` moves to 26,
and its sabotage comment updates to name the new count.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes (loop gate between edits).
- [ ] `mix test test/statifier/effect_test.exs test/statifier/session/effects_test.exs test/statifier/session/telemetry_test.exs` passes - these three are the exhaustiveness proof.
- [ ] `Telemetry.events/0` returns 26 names, asserted by the updated test.
- [ ] `mix adr.check` passes with the ADR-0040 amendment in place.
- [ ] Doctor's 100% thresholds still met (`.doctor.exs`) - the new module has a
      moduledoc and every public type is documented.
- [ ] `mix quality --format json --report -` is available if a later agent
      needs to route on results.

#### Manual Verification:
- [ ] The moduledoc table in `effect.ex`, the `@type core` union,
      `plan_one/2`, `@effect_kinds`, `core_shape/2`, and both fixture tables
      all name exactly the same ten core tags - read them side by side once.
- [ ] The ADR-0040 amendment reads as an amendment in that document's
      established voice, not as a re-argument of the settled location rule.
- [ ] No regressions in existing telemetry subscribers.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically, and Manual Verification items are deferred to the end.

---

## Phase 3: Emission at all four writes, and the reconstruction test

### Overview

Every successful `write_location/4` call site turns its `%Write{}` record into
a `{:datamodel_change, _}` effect. The acceptance test folds the stream.

### Changes Required:

#### 1. `<assign>` (call site 1)

**File**: `lib/statifier/machine/content/assign.ex`
**Changes**: `execute/2` returns a one-element effect list. The `@spec`'s
`{:ok, Context.t(), []}` widens to `{:ok, Context.t(), [Effect.t()]}`. The
defimpl comment gains a sentence: this node now produces a core effect, the
one place a `<assign>`'s written location and value reach a consumer (st-oef3,
decision 1).

```elixir
        {:ok, %{context | machine_state: machine_state, datamodel_context: datamodel_context},
         [
           {:datamodel_change,
            %Effect.DatamodelChange{
              location_path: write.path,
              location_source: location,
              new_value: write.new_value,
              prior_value: write.prior_value,
              c_index: node.c_index,
              owner: context.owner,
              macrostep: machine_state.macrostep,
              microstep: machine_state.microstep
            }}
         ]}
```

The counters are read from the **post-write** `machine_state`, which is the
same value the pre-write one carries for these two fields (the write touches
`datamodel` only) - a comment says so, so the choice is not left ambiguous.

No change to `lib/statifier/interpreter/content.ex`: the block runner already
does `effects ++ node_effects` at `:177-179`, and `Trace.ContentExecuted`
still appends after the block's own effects (`:155-158`).

#### 2. The three remaining sites share site 1's two field answers

Sites 2, 3, and 4 below give prose rather than a full struct literal, because
the literal is site 1's verbatim with different identity fields. Two fields
are stated once here so no site leaves them to be re-derived:

- `location_source` is whatever raw string that site already passes as
  `write_location/4`'s third argument - the node's `idlocation` at site 3,
  the bound `source` from `%Param{expr: {:compiled, _, source}}` at site 2
  (`interpreter.ex:783`), the `idlocation` local at site 4.
- `macrostep`/`microstep` come from the post-write `machine_state`, and the
  choice is immaterial for the same reason as at site 1: a write touches
  `datamodel` only and never the counters.

#### 3. `<send idlocation>` (call site 3)

**File**: `lib/statifier/machine/content/send.ex`
**Changes**: `maybe_write_idlocation/4` threads the `%Write{}` (or `nil`) out
to `execute/2`, which prepends the `{:datamodel_change, _}` effect **before**
the `{:send, _}`/`{:send_delayed, _}` it already returns. Order matters and is
deliberate: the datamodel write happens before the send is dispatched, and
`Session` performs instructions in the core's effect order
(`session.ex:912-919`). `c_index` and `owner` are the node's own. When
`idlocation` is absent the effect list is unchanged.

#### 4. Empty-`<finalize>` auto-assign (call site 2)

**File**: `lib/statifier/interpreter.ex` (around `:704`, `:775-800`)
**Changes**: `write_finalize_target/6` returns the effect alongside
`{machine_state, context}`, and the fold at `:704` that hardcodes `[]`
accumulates them instead. `c_index: nil`,
`owner: {:finalize, state_index, invoke_index}` - already a
`Machine.Content.owner/0` case. The `{:error, reason}` branch keeps its
`raise_platform/4` and emits nothing (decision 9).

#### 5. `<invoke idlocation>` (call site 4)

**File**: `lib/statifier/interpreter.ex` (around `:1460-1470`)
**Changes**: `maybe_write_idlocation/4` threads the `%Write{}` out; the caller
prepends `{:datamodel_change, _}` before the `{:invoke, _}` it already
returns, with `c_index: nil` and
`owner: {:invoke, state_index, invoke_index}` - the widened case declared in
`DatamodelChange`'s own `owner/0`. The abort path (ADR-0031) emits nothing.

#### 6. `Statifier.Effect` moduledoc

**File**: `lib/statifier/effect.ex`
**Changes**: the vocabulary row's "Produced by" cell moves off "not yet
produced" and names all four producers; the prose at `:45-48` adds
`:datamodel_change` to the produced list.

#### 7. Per-site tests

**Files**: `test/statifier/machine/content/assign_test.exs`,
`test/statifier/machine/content/send_test.exs`,
`test/statifier/interpreter/finalize_test.exs`,
`test/statifier/interpreter/invoke_pass_test.exs`
**Changes**: one test per site asserting the emitted effect's fields
(including `owner` and `c_index`, and `prior_value` on an overwrite), plus one
asserting a **failed** write emits no `:datamodel_change` (decision 9). Each
gets a sabotage line, e.g.
`# sabotage: Assign.execute/2 returns [] instead of the effect -> red`.

#### 8. The acceptance test

**File**: `test/statifier/session/datamodel_reconstruction_test.exs` (new)
**Changes**: the bead's criterion. A chart exercising several `<assign>`
forms - a scalar overwrite, a deep path `a.b.c`, and a bracket index
`items[1]` - is driven through a real `Statifier.Session` with a subscriber
collecting effects. The test then:

1. Writes the starting datamodel as an **explicit literal** in the test - the
   values the chart's `<data>` elements declare. A comment states this is
   decision 6's stated gap: the initial binding is not on the stream, and a
   follow-up bead covers it.
2. Folds only the `{:datamodel_change, _}` effects over that map, applying
   `new_value` at `location_path` with a small local `put_in`-style walk. The
   fold calls **no** `Session.snapshot/1` and holds no `Machine` handle.
3. Asserts the reconstructed map equals an expected literal map.
4. In a **separately labeled** assertion, compares the reconstruction against
   `Session.snapshot/1`'s datamodel as an oracle, so the two channels are
   proven to agree. The reconstruction assertion in step 3 stands without it.

`# sabotage: Assign.execute/2 drops prior_value/location_path -> red`.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes (loop gate between edits).
- [ ] `mix test test/statifier/session/datamodel_reconstruction_test.exs` passes - the bead's acceptance criterion.
- [ ] The per-site tests pass, including the failed-write-emits-nothing test.
- [ ] `mix test.regression` is green and `test/passing_tests.json` is
      unchanged, or any newly passing conformance test is added with
      `mix test.baseline add`. Emission changes no SCXML semantics, so no
      movement is the expected result; movement is a finding to report, not to
      ratchet away silently.
- [ ] `mix test --include scion --include scxml_w3` shows no new failures.
- [ ] Dialyzer clean on the widened `execute/2` `@spec`.

#### Manual Verification:
- [ ] The touched interpreter functions still match the W3C spec text they
      port - 5.4.2/5.9.2 for `<assign>`, 6.2.1 for `<send idlocation>`, 6.4.1
      for `<invoke idlocation>`, 6.5 for `<finalize>` - line for line, with no
      control-flow change beyond the added return value.
- [ ] Effect ordering reads correctly at each site: the datamodel change
      precedes the `:send`/`:invoke` it accompanies, and
      `Trace.ContentExecuted` still comes after the block's effects.
- [ ] The reconstruction test's stated gap (decision 6) is written in the test
      file itself, not only in this plan.
- [ ] No regressions in `<send>`, `<invoke>`, or `<finalize>` behavior.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are surfaced at the end.

---

## Corpus/Ratchet Notes

No corpus regeneration. This plan changes no SCXML semantics - it adds an
effect to paths that already ran - so `test/passing_tests.json` is expected to
be byte-identical after every phase. If Phase 3 does move a conformance
result, that is evidence of an unintended behavior change and is a finding to
investigate, not a baseline to add.

## Performance Considerations

The unconditional core effect adds, per successful datamodel write: one
`%Write{}` struct, one `%DatamodelChange{}` struct, and one `read_path/2` walk
of the resolved path (O(path depth), typically 1-3 segments). This is the same
order as the `Predicator.ContextLocation.put/3` already on that path, and it
is the cost decision 1 accepted in exchange for reconstruction working in
untraced runs. There is no per-microstep or per-configuration cost: nothing
here walks the datamodel, the configuration, or the machine.

## Testing Strategy

### Unit Tests:
- `test/statifier/interpreter/datamodel_test.exs` - the `%Write{}` record:
  fresh write, overwrite, deep path, bracket index, vivified container.
- `test/statifier/effect_test.exs` /
  `test/statifier/session/effects_test.exs` /
  `test/statifier/session/telemetry_test.exs` - the vocabulary's
  exhaustiveness, by their existing table-driven construction.
- Per-site emission tests under `test/statifier/machine/content/` and the
  interpreter tests, including the negative case for a failed write.
- `test/statifier/session/datamodel_reconstruction_test.exs` - the acceptance
  test.

Key edge cases: `prior_value` on a seeded-but-unbound id (`:undefined`); a
bracket path whose index is computed from the pre-assignment datamodel; a
`<send>` with no `idlocation` (no effect); a write rejected by the
system-variable check (no effect, `error.execution` unchanged).

### Manual Testing Steps:
1. Start a `Statifier.Session` on a chart with a couple of `<assign>`s,
   subscribe, and read the `{:datamodel_change, _}` effects off the mailbox -
   confirm `location_path`, `new_value`, and `prior_value` read the way an
   inspector pane would want them.
2. Attach a `:telemetry` handler to
   `[:statifier, :session, :effect, :datamodel_change]` and confirm
   `metadata.location` resolves for an `<assign>` and is `nil` for an
   `<invoke idlocation>` write.
3. Run the same chart with `trace: false` and confirm the effects still
   arrive - the point of decision 1.

## Follow-up bead to file

**Not filed by this plan; the orchestrator files it.** Decision 6 scopes this
bead to datamodel *writes*. The initial datamodel - `<data>` binding via
`Datamodel.initialize/1` and `enter_state/2`, the `:datamodel` environment
seed, and `SystemVariables.initial/2` in `MachineState.new/2` - is not on the
effect stream, so a consumer folding effects alone still needs the starting
map from another channel. A follow-up should decide between an init-time
snapshot effect and per-`<data>` binding effects, and will have to change
`initialize/1`/`enter_state/2`'s return type (their `@doc` at
`lib/statifier/interpreter/datamodel.ex:221-232` anticipates exactly this) and
find an identity for a binding, which has a `d_index` rather than a `c_index`.
It mirrors the same statifier-ui need as st-oef3 (`sui-t36.1`), so per
ADR-0025 it wants a `mirrors:` line once the other half exists.

## Residual open questions

None affecting implementation. One item is recorded rather than decided
because it belongs to another repo: the **serialization** of `new_value` /
`prior_value` for statifier-ui's ADR-0005 wire format is deliberately not
decided here (decision 8) - `docs/observability.md:175` makes "no wire format"
a non-goal for this repo, and ADR-0025 puts the wire format on predicator-ex /
statifier-ui's side of the mirror. If that repo later needs a specific
spelling for `:undefined` on the wire, it is their bead, not a gap in this
one.

## References

- Source document: `docs/research/260816-st-oef3-assign-datamodel-change-effect.md`
- Related ADRs: `docs/adr/0003-*` (pure core with effects), `docs/adr/0012-*`
  and `docs/observability.md` (observability constraints), `docs/adr/0025-*`
  (cross-repo tracker authority), `docs/adr/0031-*` (invoke abort),
  `docs/adr/0034-*` (replay re-drives the core), `docs/adr/0036-*` (`<send>`
  argument failure), `docs/adr/0037-*` (`:undefined` at the writer),
  `docs/adr/0040-*` (session telemetry contract, amended by this plan)
- Similar implementation: `lib/statifier/effect/log.ex:23-33` and
  `lib/statifier/machine/content/log.ex:49-68` - the only other content node
  whose result reaches a consumer
- Bead: st-oef3 (mirrors `sui-t36.1`)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions still match the W3C spec prose they port (5.4.2 /
      5.9.2 / 5.10); no Appendix D pseudocode is involved, per "The Appendix D
      rule" above.
- [ ] `read_path/2`'s `:undefined` is genuinely indistinguishable from a
      stored `:undefined` and that is documented as accepted (decision 4), not
      silently glossed.
- [ ] No regressions in `<send idlocation>` / `<invoke idlocation>` /
      `<finalize>` behavior.

**Implementation Note**: Use the project's loop gate between edits; run the
full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end.

---
