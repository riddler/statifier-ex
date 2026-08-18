# Send reachability judged against a route snapshot - Implementation Plan

## Overview

Implement ADR-0048: teach the pure core to judge `<send>` target
*reachability* against a caller-declared route snapshot carried on
`%MachineState{}`, so C.1's `error.communication` is raised at the `<send>`'s
own position inside its block (4.9 abort included) rather than post-hoc from
`Statifier.Session.deliver/5`. Bead: st-72dn.

This plan implements ADR-0048; it does not re-argue it. Shape C (snapshot),
shape D's rejection, block abort on core-detected unreachability, the
staleness reading, and the "no fifth recording input" rule are all settled
there and are inputs here.

## Current State Analysis

**The failure.** `test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs:19-42`
sends to `#_scxml_foo` and then `<raise event="foo"/>` in one `<onentry>`.
`Statifier.Send.Target.parse/1` (`lib/statifier/send/target.ex:63`) answers
`{:session, "foo"}` from the string alone - deliberately nothing about
liveness - so ADR-0047's static arm in
`lib/statifier/machine/content/send.ex` passes it through as a
`%Effect.Send{}`. `Statifier.Interpreter.handle_event/2`
(`lib/statifier/interpreter.ex:436-457`) folds `main_event_loop/1` to
quiescence before returning, so by the time
`Statifier.Session.deliver/5`'s registry lookup misses
(`lib/statifier/session.ex:1292-1300`) and `communication_error/4`
(`lib/statifier/session.ex:1395`) re-enters through ADR-0039's
`deliver_internal/5`, the sibling `<raise>`'s `foo` has been dequeued,
matched by `<transition event="*">`, and the machine sits in `fail`.

**What already exists and is reused unchanged.**

- The rejection channel ADR-0047 built: `execute/2` mints the send id and
  writes `idlocation` first, then `dispatch_or_reject/8` returns the
  composite `{:error, context, {:send_rejected, send_id, reason}}`
  (`lib/statifier/machine/content/send.ex`, `reject_reason/2` and the
  `dispatch_or_reject/8` rejection arm). `run_nodes/2`'s three-element
  `{:error, new_context, reason}` arm keeps the advanced `send_counter` and
  the datamodel write (`lib/statifier/interpreter/content.ex`).
- The conversion site: `raise_execution_error/4`'s `{:send_rejected, _, _}`
  clause in `lib/statifier/interpreter/content.ex`, which today hardcodes
  `"error.execution"` and stamps `sendid:`.
- `Statifier.Session.Invocations.invoke_ids/1` (the live invoke ids),
  `State.invoked_by` (parent presence), `State.session_id`, and
  `Statifier.Registry` (`keys: :unique`, started in
  `lib/statifier/supervisor.ex:63`).
- `Statifier.Session.Recording` (`lib/statifier/session/recording.ex`) with
  six entry kinds plus normalized `opts`, and `Statifier.Replay`
  (`lib/statifier/replay.ex`) folding those entries through the pure core.

**What is missing.** There is no field on `%MachineState{}`
(`lib/statifier/machine_state.ex:336-357`) that holds any claim about live
routes, no struct to hold one, no reachability arm in `execute/2`, no way for
the fatal channel to name an error other than `error.execution`, no snapshot
construction in `Statifier.Session`, and no place in a recording for a
per-drive snapshot.

**Two facts that shape the phasing.**

1. `Statifier.Case.test_scxml/4` routes test496 through
   `drive_through_session/3` (`test/support/case.ex:139-142`), because
   `:send_elements` is in `@session_features` (`test/support/case.ex:90-101`).
   So test496 only goes green once `Statifier.Session` builds real
   snapshots - the core arm alone is not enough.
2. `test/passing_tests.json` lists test159 (`:146`) and test332 (`:267`) but
   not test496, which is the ratchet gap this bead closes.

### Key Discoveries:

- ADR-0048 decision 1 fixes the check's home: beside ADR-0047's static check
  in `Statifier.Machine.Content.Send.execute/2`, judged against a value, never
  a lookup.
- ADR-0048 decision 2 fixes the carrier: a `%MachineState{}` field, `nil`
  meaning "no determination", stamped per drive - not a threaded parameter,
  because ADR-0012 constraint 1 makes a paused microstep's resumable position
  the struct itself.
- ADR-0048 decision 3 fixes the replay shape: the snapshot is an attribute of
  each recorded drive, not a fifth input; ADR-0029's four-input tuple is
  unchanged in kind and `Statifier.Replay` stays a pure fold (ADR-0034).
- ADR-0048 decision 6 fixes two things at once: core-detected unreachability
  aborts the block (4.9), and **delayed sends get no plan-time reachability
  check at all** (6.2.3 governs argument evaluation; the route is resolved at
  timer-fire time). The reachability arm must therefore be gated on
  `delay_ms == nil`, unlike ADR-0047's static arm which covers both.
- ADR-0048 decision 4: the session includes its own `session_id` in the
  snapshot, so `#_scxml_<self>` is reachable with no registry involved;
  `deliver/5`'s existing self-clause (`lib/statifier/session.ex:1288`) still
  performs the enqueue.
- ADR-0048 decision 5 and the consequences: the residual post-hoc path
  (`communication_error/4`) stays, with a real caseload - stale snapshots,
  `nil`-snapshot drives, `interpret/2`-injected effects, and delayed sends
  missing at fire time.
- ADR-0002's Appendix D rule: this plan adds no deviation from the
  pseudocode. `deliver_internal/5`'s existing mechanical deviation
  (ADR-0039's re-entry door) is untouched, and no Appendix D procedure gains
  or loses a step - the reachability judgment happens inside `executeContent`'s
  leaf, which Appendix D leaves to the platform.

## Desired End State

After this plan:

- `Statifier.Send.Routes` exists as a plain value in ADR-0047's neutral
  namespace, answering "is this route reachable" for `{:session, sid}`,
  `:parent`, and `{:invoke, id}`, and answering `true` by construction for
  `:self` and `:internal`.
- `%MachineState{}` carries `routes: Routes.t() | nil`, defaulted `nil`, set
  through `MachineState.new/2`'s `:routes` option and
  `MachineState.put_routes/2`.
- An immediate `<send>` whose route the snapshot declares unreachable is
  rejected inside `execute/2` after the send id is minted and `idlocation`
  written, halting its block (4.9) and raising `error.communication` (C.1,
  6.2.4's "unable to dispatch" arm) carrying that `sendid`.
- `Statifier.Session` builds and stamps a snapshot at every recordable input
  boundary, and every `Statifier.Session.Recording` entry plus the recording's
  `opts` carries the snapshot in force for the drive it triggers, so
  `Statifier.Replay` re-supplies it and a recorded run replays identically.
- test496 passes and is in `test/passing_tests.json`; test159 and test332
  still pass; the residual ADR-0039 path still works for every case decision
  5 names.

Verification: `mix quality` green; `mix test.regression` green with test496
listed; `mix test --include scxml_w3 test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`
green.

## What We're NOT Doing

- **Not** moving the registry seam. The core never calls
  `Statifier.Registry`, never holds a pid or monitor (ADR-0027 unamended,
  ADR-0048 decision 4).
- **Not** adding a fifth recording input, and not adding a new recording
  *entry kind*. Existing entries widen (ADR-0048 decision 3).
- **Not** implementing shape D (a resolver capability) or shape E (suspending
  the macrostep). Both are rejected in ADR-0048 decision 1; a plan cannot
  reopen them.
- **Not** giving delayed sends a plan-time reachability check (ADR-0048
  decision 6).
- **Not** removing `Statifier.Session`'s `communication_error/4` or the
  planner's `{:invalid, _}`/unsupported-type arms. Both keep a real caseload
  (ADR-0047 decision 4, ADR-0048 decision 5).
- **Not** adding a trace/cause distinction between the core-raised and
  session-raised `error.communication`. ADR-0048 records that as an open
  question belonging to its first consumer; nothing consumes it today.
- **Not** narrowing or lazily building the snapshot for cost. ADR-0048's
  consequences accept O(live sessions) per stamping and name a measured
  embedder workload as the reopen trigger.
- **Not** touching `mix.exs`'s `2.0.0-dev`, and not weakening any gate check:
  no `@tag :skip`, no threshold move, no `test/passing_tests.json` shrink
  (ADR-0011; those need a human's ledger entry in
  `docs/quality-gate-changes.md`).
- **Not** regenerating the corpus. test496's file is generator output
  (`tools/corpus/scxml_w3/cases.exs:169`) and is already committed; nothing
  here changes what the generator emits.

## Implementation Approach

Four phases, bottom-up along the value's path: the value itself, the core
that reads it, the recording that carries it, the session that produces it.
Each phase is independently committable with a full green `mix quality`;
only phase 4 changes observable behavior, which is why the ratchet entry
rides in phase 4's commit (`.claude/wurk/commit.md`: the ratchet update lands
in the same commit as the change that unlocked it).

### The one design call this plan makes, and why

ADR-0048 decision 2 says the snapshot is "stamped by the caller before every
core drive - `initialize`, each `handle_event/2`, and each
`Interpreter.deliver_internal/5` re-entry". Decision 3 says each *recorded
entry that triggers a core drive* carries the snapshot stamped for that
drive. Those two sentences meet a wrinkle in the live session that the record
does not resolve explicitly, so this plan resolves it and states the
resolution:

Not every `handle_event/2` call in `Statifier.Session` follows a recorded
input. A `<send target="#_self">` (or any `:self` route) plans to
`{:enqueue_event, event}`, lands on `Statifier.Session.Inbox`, and is drained
by the same `handle_continue(:drain, _)` that is already running - a *derived*
drive with no recorded entry of its own, because `Statifier.Replay` re-derives
it rather than replaying it.

**Decision: the session stamps at every recordable input boundary, and a
derived drive inside the same drain reads the snapshot already on
`%MachineState{}`.** The stamping sites are therefore exactly:
`init/1` (via `MachineState.new/2`'s `:routes` option), `handle_cast`'s
`{:enqueue_event, _}`, `{:enqueue_invoked_event, _, _}`, `:enqueue_cancel`
and `{:interpret, _}`, `handle_info`'s `{:statifier_delayed_send, ...}`, and
`deliver_internal/6`.

Three reasons, which is why this is a plan decision rather than a coin flip:

1. It satisfies decision 3 by construction. Every stamping is recorded at its
   own recorded entry, so replay re-supplies exactly what the live run judged
   against, and a recorded run reproduces (ADR-0034's round-trip obligation).
2. It satisfies decision 2's stated purpose. `deliver_internal/6` is on the
   list, so an ADR-0044 mid-macrostep re-entry gets current truth rather than
   the macrostep-opening read - the case decision 2 argues from.
3. Re-reading the registry mid-drain would be point-in-time truth at a point
   no recording can name. Since decision 3 requires recordability, the
   stamping sites *must* be the recordable boundaries; a stamping nobody can
   record is a stamping replay cannot reproduce.

Anyone who reads decision 2's "each `handle_event/2`" as literally including
derived drives should note the consequence - a live/replay divergence window
- and take it to an amendment rather than to this plan.

---

## Phase 1: The `Statifier.Send.Routes` value and its `%MachineState{}` slot

### Overview

Introduce the snapshot as a value with its own unit tests, and give
`%MachineState{}` the field and the two ways to set it. Nothing reads it yet.

### Changes Required:

#### 1. The route snapshot

**File**: `lib/statifier/send/routes.ex` (new)
**Changes**: A struct in ADR-0047 decision 3's neutral namespace, carrying
exactly what `Statifier.Session.deliver/5` resolves today, plus a predicate
over `Statifier.Send.Target.route()`.

```elixir
defstruct sessions: MapSet.new(), parent?: false, invokes: MapSet.new()

@type t :: %__MODULE__{
        sessions: MapSet.t(String.t()),
        parent?: boolean(),
        invokes: MapSet.t(String.t())
      }

@spec new(opts :: keyword()) :: t()

# `:self` and `:internal` need no entry - reachable by construction
# (ADR-0048 decision 1). `{:invalid, _}` is never asked: ADR-0047's static
# arm rejects it first, in the same `execute/2`.
@spec reachable?(routes :: t(), route :: Target.route()) :: boolean()
def reachable?(_routes, :self), do: true
def reachable?(_routes, :internal), do: true
def reachable?(%__MODULE__{sessions: s}, {:session, sid}), do: MapSet.member?(s, sid)
def reachable?(%__MODULE__{parent?: parent?}, :parent), do: parent?
def reachable?(%__MODULE__{invokes: i}, {:invoke, id}), do: MapSet.member?(i, id)
def reachable?(_routes, {:invalid, _target}), do: false
```

The moduledoc states: this is a caller-declared claim, point-in-time, with no
obligation to track anything between writes (ADR-0048 decision 2's answer to
ADR-0030's ground 2), and it is deliberately *not*
`MachineState.active_invocations`, which is the algorithm's view of which
invocations are active rather than whether their processes are alive.

#### 2. The `%MachineState{}` field and its setters

**File**: `lib/statifier/machine_state.ex`
**Changes**: add `routes: nil` to the struct and `routes: Routes.t() | nil`
to `@type t`; document `nil` as "no determination made" in a `@typedoc`;
read `:routes` in `new/2` (`Keyword.get(opts, :routes)`); add
`put_routes/2`; make the existing private `generate_session_id/0` public
with a `@doc`, so `Statifier.Session` can resolve the id it must put in the
snapshot before `Interpreter.initialize/2` runs (phase 4 needs this; landing
it here keeps phase 4 to one concern).

```elixir
@spec put_routes(machine_state :: t(), routes :: Statifier.Send.Routes.t() | nil) :: t()
def put_routes(%__MODULE__{} = machine_state, routes),
  do: %{machine_state | routes: routes}
```

`Statifier.Interpreter.initialize/2` needs no change: its own `@doc` records
that "`opts` passes straight to `MachineState.new/2` - no option is
interpreted here, so a new one is a `MachineState` change, not an
entry-point change" (`lib/statifier/interpreter.ex:209-211`).

#### 3. Tests

**Files**: `test/statifier/send/routes_test.exs` (new),
`test/statifier/machine_state_test.exs` (extend)
**Changes**: `reachable?/2` over every `route()` constructor including
`{:invalid, _}`; an empty snapshot rejecting each of the three
snapshot-answerable routes; `new/2` defaults; the `%MachineState{}` default
of `nil`; `MachineState.new/2` with and without `:routes`; `put_routes/2`
setting and clearing.

Every new test here asserts `lib/` behavior, so every one carries a verified
`# sabotage: ...` note per `.claude/wurk/implement.md` - break the clause it
covers, confirm red, revert, record the mutation in one line.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not a phase gate on
      its own)
- [x] Full `mix quality` green, including Doctor's 100% doc thresholds for the
      new public module and the newly public `generate_session_id/0`
- [x] `mix gate.verify` confirms the green was a full, unscoped, unskipped run
- [x] `test/statifier/send/routes_test.exs` exists and every test in it carries
      a `# sabotage:` note
- [x] `mix test` (internal suite) green - no behavior changed, so nothing moves

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      here vacuously: no Appendix D procedure is touched, and the reviewer
      confirms that by inspection of the diff
- [ ] `Routes.reachable?/2`'s clause set is read against ADR-0048 decision 1's
      "the check covers every route the snapshot can answer - `{:session, sid}`,
      `:parent`, and `{:invoke, invokeid}` - one rule, not a test496-shaped
      special case"
- [ ] Each sabotage note was actually verified red, not written from belief

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The core reachability arm and the parameterized fatal channel

### Overview

Add the reachability check beside ADR-0047's static check in
`execute/2`, and widen `Statifier.Interpreter.Content`'s fatal conversion so
the raised error name is a parameter rather than a constant. After this phase
a core drive with a stamped snapshot behaves per ADR-0048; a `nil` snapshot
behaves exactly as today. test496 is still red, because nothing stamps yet.

### Changes Required:

#### 1. The reachability arm

**File**: `lib/statifier/machine/content/send.ex`
**Changes**: `dispatch_or_reject/8` already holds the post-mint decision
point and already has `machine_state` in hand. Widen `reject_reason/2` to
take the resolved `delay_ms` and the snapshot, and add a third `cond` arm
after the two ADR-0047 arms:

```elixir
# ADR-0048: reachability, judged against the caller-declared snapshot on
# `%MachineState{}` - a value, never a lookup (ADR-0003/ADR-0027 stay
# structural). `nil` routes means the driver declared nothing, so the core
# makes no determination and the effect is emitted exactly as before; the
# session's `deliver/5` boundary is still the detector on that path
# (ADR-0048 decision 5). A delayed send is exempt: 6.2.3 governs *argument*
# evaluation at element-evaluation time and reachability is not an argument,
# so the route is resolved when the timer fires (ADR-0048 decision 6).
defp reject_reason(target, type, delay_ms, routes) do
  cond do
    not Target.supported_type?(type) -> {:execution, {:unsupported_type, type}}
    match?({:invalid, _reason}, Target.parse(target)) -> {:execution, {:invalid_target, target}}
    unreachable?(target, delay_ms, routes) -> {:communication, {:unreachable_target, target}}
    true -> nil
  end
end

defp unreachable?(_target, _delay_ms, nil), do: false
defp unreachable?(_target, delay_ms, _routes) when is_integer(delay_ms), do: false
defp unreachable?(target, nil, routes), do: not Routes.reachable?(routes, Target.parse(target))
```

The rejection arm then returns
`{:error, new_context, {:send_rejected, send_id, kind, reason}}` where `kind`
is `:execution | :communication`.

**The error name stays out of this file on purpose.** The leaf carries an
atom kind, not the string `"error.communication"`, so
`Statifier.Interpreter.Content` remains the only site in the tree that names
an `error.*` event for content - the property
`test/statifier/interpreter/content_acceptance_test.exs`'s AC3 structural
sweep (`:162-169`) and ADR-0003's error model both rest on.

That sweep today greps leaf modules for the literal `"error.execution"` only.
Extend its predicate to `"error.communication"` in the same phase: the
property it asserts is "a leaf never names an `error.*` event", and this
change is the first time a second name exists to be misplaced. This is a
strengthening of an existing check, not a new one, and it is not a gate-guarded
file.

#### 2. The parameterized conversion

**File**: `lib/statifier/interpreter/content.ex`
**Changes**: the `{:send_rejected, _, _}` clause of
`raise_execution_error/4` becomes the four-element form and maps the kind to
a name:

```elixir
defp raise_execution_error(machine_state, owner, c_index, {:send_rejected, send_id, kind, reason}) do
  MachineState.raise_platform(machine_state, error_name(kind), {:content, c_index, owner},
    data: reason,
    sendid: send_id
  )
end

defp error_name(:execution), do: "error.execution"
defp error_name(:communication), do: "error.communication"
```

`raise_platform/4` is still correct for both: 5.10.1 classifies `error.*` as a
platform event regardless of which `error.*` it is, and 3.12.2 is what puts it
on the internal queue. Update the moduledoc's "A node may name a send id"
section to say the node now names the *event* as well as the id, citing
ADR-0048 decision 6, and keep its existing sentence that this clause is
reachable from the fatal arm only (5.9.1's `pending_errors` drain is the
non-fatal channel and no node puts a `{:send_rejected, ...}` reason there).

#### 3. Tests

**Files**: `test/statifier/machine/content/send_test.exs` (extend the
existing `describe "execute/2 - static target/type rejection (ADR-0047)"`
neighborhood with a new `describe` for ADR-0048),
`test/statifier/interpreter/content_test.exs` (extend)
**Changes**:

- `execute/2` with a stamped snapshot that omits the target session rejects
  with `{:send_rejected, send_id, :communication, {:unreachable_target, "#_scxml_foo"}}`
  and produces no `Effect.Send`.
- The same document with the session id *in* the snapshot dispatches normally.
- `:parent` unreachable when `parent?: false`, reachable when `true`;
  `{:invoke, id}` likewise against `invokes`.
- `#_scxml_<own id>` is reachable when the snapshot's `sessions` contains it
  (ADR-0048 decision 4's mirror, asserted at the core layer).
- `routes: nil` emits the effect - today's behavior, unchanged.
- A **delayed** send to an unreachable target still emits
  `%Effect.SendDelayed{}` (ADR-0048 decision 6's exemption).
- Precedence: an unsupported `type` still wins over an unreachable target,
  and an `{:invalid, _}` target still rejects as `:execution`, so ADR-0047's
  arms keep priority.
- The send id is still minted and `idlocation` still written before the
  reachability rejection (the test332 ordering, asserted directly at the
  core layer rather than only through the corpus).
- Block-level: a block of `[send-to-unreachable, raise]` run through
  `Statifier.Interpreter.Content.execute_block/3` queues
  `error.communication` with the right `sendid` and does **not** run the
  `<raise>` (4.9) - this is test496's mechanism, asserted without a session.

Every one of these asserts `lib/` behavior and needs a verified
`# sabotage:` note.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating
- [x] Full `mix quality` green
- [x] `mix gate.verify` confirms a full, unscoped run
- [x] `mix test.regression` green - test159 and test332 still pass, and no
      already-ratcheted conformance test moves
- [x] `mix test --include scxml_w3 --include scion` shows test496 still red
      (this phase does not claim it) and no *new* red file
- [x] `mix test test/statifier/interpreter/content_acceptance_test.exs` green
      with AC3 widened to `error.communication`

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line;
      specifically `executeContent`'s block semantics in
      `Statifier.Interpreter.Content` are unchanged in structure - only the
      name the conversion raises is now a parameter
- [ ] The 4.9 quote in the moduledoc still describes what the code does, read
      against the local spec cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
      not from memory
- [ ] `Statifier.Machine.Content.Send` still names no `error.*` string
      anywhere (grep the file), and AC3's widened sweep is what proves it
      rather than the grep alone
- [ ] Each sabotage note was actually verified red

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Recording and replay carry the per-drive snapshot

### Overview

Widen every `Statifier.Session.Recording` entry and the recording's `opts` to
carry the snapshot in force for the drive that entry triggers, and make
`Statifier.Replay` re-supply it before each drive. `Statifier.Session` wires
the real value through - `state.machine_state.routes` - which is still `nil`
until phase 4, so this phase changes no behavior and no recorded run's
content. It changes the entry *shape*, which is why it is its own commit.

### Changes Required:

#### 1. The recording

**File**: `lib/statifier/session/recording.ex`
**Changes**: add `:routes` to `@normalized_opts` (defaulted `nil`), so the
session-start initialization's snapshot rides where every other
`MachineState.new/2` option already rides - the "session-start
initialization" third of ADR-0048 decision 3. Widen `entry()` and each
`put_*` function by one trailing `routes` argument:

```elixir
@type entry ::
        {:event, Event.t(), Routes.t() | nil}
        | {:invoked_event, invoke_id :: String.t(), Event.t(), Routes.t() | nil}
        | {:cancel, Routes.t() | nil}
        | {:timer, send_id :: String.t() | nil, Event.t(), Routes.t() | nil}
        | {:interpret, [Effect.t()], Routes.t() | nil}
        | {:internal, kind :: :internal | :platform, name :: String.t(),
           Cause.origin(), opts :: keyword(), Routes.t() | nil}
```

Note `:cancel` becomes a tagged tuple rather than a bare atom; a cancel drives
`Interpreter.cancel/1`, whose `exit_interpreter/1` walk runs `<onexit>` blocks
that may contain `<send>`, so it needs a snapshot like any other drive.

The moduledoc gains a section stating what the snapshot is, why it is an
attribute of the entry rather than a fifth input (ADR-0029's tuple is
unchanged in kind), and that `nil` means the driver declared nothing.

#### 2. Replay

**File**: `lib/statifier/replay.ex`
**Changes**: each `apply_entry/2` clause destructures the entry's `routes`
and stamps it with `MachineState.put_routes/2` before the drive it triggers -
`drain/1` for the enqueueing kinds, `perform_internal/5` for `{:internal,
...}`, `perform/2` for `{:interpret, ...}`. `Interpreter.initialize/2`
already receives `Recording.opts/1`, so the initialization snapshot needs no
new code path. The moduledoc gains a paragraph: replay re-supplies the
recorded snapshot rather than rebuilding one, which is exactly why the
module stays a pure fold with no registry anywhere (ADR-0034, ADR-0048
decision 1's replay-cost ground).

#### 3. Session call sites

**File**: `lib/statifier/session.ex`
**Changes**: every `record(state, &Recording.put_*/...)` call passes
`state.machine_state.routes`; `Recording.new/2` receives `machine_opts`
already carrying `:routes` (phase 4 fills it). No stamping yet.

#### 4. Observability doc

**File**: `docs/observability.md`
**Changes**: constraint 6's Replay bullet gains the sentence ADR-0048
decision 3's consequences require - each recorded entry that triggers a core
drive carries the route snapshot that drive was judged against, and the set
of recorded input kinds does not grow.

#### 5. Tests

**Files**: `test/statifier/session/recording_test.exs`,
`test/statifier/replay_test.exs`, `test/statifier/replay_round_trip_test.exs`,
`test/statifier/session_test.exs` (the `describe "recording"` block,
`:1159-1290` - exact-tuple matches against `Recording.entries/1` at `:1189`,
`:1210`, `:1239`, and `:1274-1277`), and
`test/statifier/session/invoke_cancel_test.exs:262` (a three-element
`match?({:invoked_event, _, %Event{...}}, &1)` inside a `wait_until/1`, which
would *time out* rather than fail cleanly once the entry widens - fix it
before running the phase's suite so the red is legible)
**Changes**: existing entry-shape assertions update to the widened tuples.
Grep for `Recording.entries(` and for each entry tag (`{:event,`,
`{:invoked_event,`, `:cancel`, `{:timer,`, `{:interpret,`, `{:internal,`)
across `test/` before starting - the five sites above are the ones found
during planning, and the grep is what makes the list exhaustive at
implementation time. New tests:

- `put_*` round-trips a non-`nil` snapshot into `entries/1` for every entry
  kind, at its position.
- `new/2` normalizes `:routes` into `opts/1`, defaulting `nil`.
- `Replay.run/1` over a hand-built recording whose entry carries a snapshot
  omitting the target session reaches the configuration the core's
  reachability arm produces - i.e. replay *stamps*, and a recording whose
  entry carries `nil` reproduces today's post-hoc path. This is the pair that
  proves the re-supply is real rather than dropped on the floor.
- The existing `term_to_binary/1`/`binary_to_term/1` round-trip still holds
  with snapshots present (a `MapSet` in an entry is still a plain term).

Every new test asserts `lib/` behavior and needs a verified `# sabotage:`
note. Updates to existing tests keep their existing notes; a note that no
longer describes the mutation gets re-verified and rewritten.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating
- [ ] Full `mix quality` green
- [ ] `mix gate.verify` confirms a full, unscoped run
- [ ] `mix test.regression` green - no conformance movement, since nothing
      stamps a non-`nil` snapshot yet
- [ ] `mix quality --format json --report -` parses, for the looped runner's
      own routing
- [ ] `grep -rn "Recording.entries(" test/` shows no remaining three-element
      `{:event, _}` / bare `:cancel` / three-element `{:invoked_event, _, _}`
      pattern against a recording entry

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      `Statifier.Replay` reimplements no Appendix D function (its own moduledoc
      claims this; confirm the diff does not break the claim)
- [ ] `docs/observability.md` constraint 6 reads correctly against ADR-0029's
      four-input tuple: entries got richer, the input set did not grow
- [ ] The widened `entry()` typedoc and `Statifier.Replay`'s clauses agree
      shape for shape, with no clause silently ignoring its snapshot
- [ ] Each sabotage note was actually verified red

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: The session builds and stamps the snapshot; test496 enters the ratchet

### Overview

Build the snapshot in `Statifier.Session` and stamp it at every recordable
input boundary. This is the phase that changes observable behavior, makes
test496 pass, and carries the ratchet entry and the changelog fragment in its
own commit.

### Changes Required:

#### 1. Snapshot construction

**File**: `lib/statifier/session.ex`
**Changes**: one private builder, the single place the three facts are read:

```elixir
# ADR-0048 decision 1/4: exactly what `deliver/5` below resolves - the
# registry's keys plus this session's own id (a session is accessible to
# itself whether or not it is registered, the mirror of `deliver/5`'s own
# self-clause), whether a parent exists, and the live invoke ids from this
# session's own table. Point-in-time truth by definition (decision 5); the
# registry enumeration is O(live sessions) per stamping, accepted in the
# record's consequences.
@spec routes(state :: State.t()) :: Routes.t()
defp routes(%State{} = state) do
  Routes.new(
    sessions: MapSet.put(registry_keys(), state.session_id),
    parent?: state.invoked_by != nil,
    invokes: MapSet.new(Invocations.invoke_ids(state.invocations))
  )
end

# `Registry.select/2` over a `keys: :unique` registry, with the same
# `ArgumentError` rescue `registry_lookup/1` already carries for the
# "no runtime placed" case - a bare `start_link/2` sender is allowed to be
# in it, and it simply declares no reachable peers.
defp registry_keys do
  Statifier.Registry
  |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  |> MapSet.new()
rescue
  ArgumentError -> MapSet.new()
end
```

#### 2. Stamping

**File**: `lib/statifier/session.ex`
**Changes**: a `stamp/1` helper that sets `state.machine_state.routes` via
`MachineState.put_routes/2`, called at each recordable input boundary
immediately before the entry is recorded, so the recorded entry and the
stamped struct carry the same value by construction:
`handle_cast({:enqueue_event, _})`, `handle_cast({:enqueue_invoked_event, _, _})`,
`handle_cast(:enqueue_cancel)`, `handle_cast({:interpret, _})`,
`handle_info({:statifier_delayed_send, ...})`, and `deliver_internal/6`.
Each site gets the one-line reason from "The one design call this plan makes"
above, stated once in a private-function doc comment and referenced from the
sites.

#### 3. Initialization ordering

**File**: `lib/statifier/session.ex`
**Changes**: `init/1` currently learns `session_id` *from*
`Interpreter.initialize/2`'s result and registers afterwards. To stamp the
initialization drive the id must exist first:

1. `session_id = Keyword.get_lazy(opts, :session_id, &MachineState.generate_session_id/0)`
   (public as of phase 1).
2. `register_session(session_id)`.
3. Build the snapshot (no `%State{}` exists yet, so the builder's inputs are
   passed directly rather than read off a struct - keep one builder and give
   it the three values, not the struct, if that is what keeps it single).
4. `machine_opts` gains both `:session_id` and `:routes`; `Interpreter.initialize/2`
   passes them straight to `MachineState.new/2`.
5. `Recording.new(machine, machine_opts)` - the `Keyword.put(:session_id, ...)`
   at `lib/statifier/session.ex:575` becomes redundant and goes.

Registering before `Interpreter.initialize/2` is safe: `init/1` processes no
message, so anything another session casts at the newly registered name waits
in the mailbox. The existing comment at
`lib/statifier/session.ex:620-634` explaining why registration follows
initialization is rewritten to explain why it now precedes it.

#### 4. The residual path's comment

**File**: `lib/statifier/session.ex`
**Changes**: `communication_error/4`'s doc comment cites ADR-0048 and names
its remaining caseload explicitly (decision 5): a stale snapshot, a
`nil`-snapshot drive, an `interpret/2`-injected effect, and a delayed send's
route miss at fire time. It is a boundary check with a real caseload, not
dead code.

#### 5. Tests that will need updating, not just adding

Phase 4 moves detection for **all three** snapshot-answerable routes, so
several existing session tests change mechanism even where the final
configuration is the same. The implementer must read each and decide whether
the assertion is still the right one, rather than editing until green:

- `test/statifier/session_test.exs:965-995` - `#_scxml_<unknown>` now raises
  `error.communication` from the core, at the send's position, with the block
  aborted. (A different block from the `describe "recording"` one phase 3
  touches, and for a different reason: behavior here, entry shape there.)
- `test/statifier/session_runtime_test.exs:115-153` - "never existed" and
  "has since died". The first is now core-detected; the second is
  snapshot-dependent (dead before the stamping -> core; died after -> the
  residual path). This pair is the best available direct test of ADR-0048
  decision 5's staleness reading and should be shaped to assert *both*.
- `test/statifier/session/invoke_send_target_test.exs:107,135` and
  `test/statifier/session/invoke_parent_routing_test.exs:142` - `{:invoke, _}`
  and `:parent` misses are now core-detected too.
- `test/statifier/replay_round_trip_test.exs:527-548` - the recorded run that
  crossed the ADR-0039 seam via `communication_error/4` no longer crosses it;
  the round-trip assertion stands but the entry list it round-trips changes.
  Keep a round-trip test for the *residual* crossing as well, so ADR-0039's
  door stays covered.
- `test/statifier/session/send_cancel_test.exs` and the delayed-send tests -
  confirm a delayed send to an unreachable target still schedules (decision
  6's exemption) end to end, not only at the core layer.

#### 6. New tests

**Files**: `test/statifier/session_test.exs`, `test/statifier/session_runtime_test.exs`
**Changes**:

- A `<send target="#_scxml_foo"/>` followed by a sibling in one `<onentry>`:
  the sibling does not run, and `error.communication` carries the send's id
  (test496's shape, asserted at the session layer with real assertions rather
  than only through the corpus file).
- `#_scxml_<own session id>` still delivers to self (ADR-0048 decision 4).
- A live peer session registered in `Statifier.Registry` is reachable and
  receives the event, with no error raised.
- The recorded run of the above carries a non-`nil` snapshot on its entries
  and replays to the same configuration (the phase-3 machinery, now with real
  values).

Every new test asserts `lib/` behavior and needs a verified `# sabotage:`
note.

#### 7. Ratchet, changelog, and the sibling fragment

**Files**: `test/passing_tests.json`, `changelog.d/st-72dn.md` (new),
`changelog.d/st-yizi.md`
**Changes**:

- `mix test.baseline add test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`
  - which verifies the file passes on its own before writing - in **this**
  commit, per `.claude/wurk/commit.md`. This is a registry *growth*, which
  `mix gate.check` permits; only a shrink needs a ledger entry.
- `changelog.d/st-72dn.md`: this is user-visible behavior (a changed error
  event position and a block that no longer runs to completion), and it is a
  capability v1 never had, so `changelog.d/README.md`'s narrower
  while-v2-is-unreleased rule is satisfied - a fragment is written.

  ```markdown
  ### Fixed

  - A `<send>` whose target names a session, parent, or invocation that is
    not reachable now raises `error.communication` at the `<send>`'s own
    position, carrying its `sendid`, and the rest of the enclosing block does
    not run (spec 4.9, C.1). A target that becomes unreachable after the block
    has run still raises the error afterwards, as before.
  ```

- `changelog.d/st-yizi.md`'s closing sentence ("A target that names a special
  target but resolves to no live session is unchanged: it still raises
  `error.communication` after the block.") becomes false with this change.
  Both fragments are unreleased and are assembled into one section at release,
  so leaving the contradiction would ship a wrong changelog. Delete that one
  sentence from `changelog.d/st-yizi.md`; st-72dn's own fragment states the
  new truth. This is the one deliberate cross-fragment edit
  `changelog.d/README.md`'s one-file-per-issue rule does not anticipate, and
  it is safe because st-yizi has already landed on `main`.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating
- [ ] Full `mix quality` green
- [ ] `mix gate.verify` confirms a full, unscoped, unskipped run
- [ ] `mix test --include scxml_w3 test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`
      passes
- [ ] `mix test.baseline add test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`
      succeeds and `test/passing_tests.json` contains that path
- [ ] `mix test.regression` green with test496 in the registry, and test159 and
      test332 still listed and passing
- [ ] `mix test --include scxml_w3 --include scion` shows no file newly red
      against the pre-branch run
- [ ] `mix gate.check` passes with no ledger entry required (the registry grew;
      no guarded file moved)
- [ ] `changelog.d/st-72dn.md` exists

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line;
      `Statifier.Session` is outside Appendix D by construction (ADR-0003), and
      the reviewer confirms no interpreter procedure changed in this phase
- [ ] C.1's two paragraphs and 4.9's block rule are re-read from the local
      spec cache and the behavior matches both - the error lands on the
      *sending* session's internal queue, and the rest of the block does not run
- [ ] Each existing test listed under "Tests that will need updating" was read
      and re-decided, not edited until green
- [ ] The residual ADR-0039 path is exercised by at least one test after the
      change (a session that dies after the stamping), so decision 5's staleness
      reading has a live witness
- [ ] Each sabotage note was actually verified red

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

- No corpus regeneration. test496's test file is already committed generator
  output (`tools/corpus/scxml_w3/cases.exs:169`); `mise run corpus` is not part
  of this plan and would produce no diff for it.
- `test/passing_tests.json` grows by exactly one entry,
  `test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`, written
  by `mix test.baseline add` in phase 4's commit. The ratchet only moves
  forward; nothing is removed.
- If phase 4 turns any already-ratcheted file red, that is a regression to fix
  in phase 4, never a registry line to delete (ADR-0011, `mix gate.check`).
- Other W3C tests in this area may also start passing as a side effect (the
  `:parent` and `{:invoke, _}` arms move too). `mix test.baseline` without
  `add` reports them; ratcheting any of them in is a judgment call for the
  implementer, and each must pass on its own first.

## Testing Strategy

### Unit Tests:

- `test/statifier/send/routes_test.exs` - `reachable?/2` over the whole
  `Target.route()` vocabulary, empty snapshot, and `new/2` defaults.
- `test/statifier/machine_state_test.exs` - the `routes` field's default,
  `new/2`'s `:routes` option, `put_routes/2`.
- `test/statifier/machine/content/send_test.exs` - the reachability arm:
  reachable, unreachable, `nil` snapshot, delayed exemption, precedence
  against ADR-0047's two arms, mint-before-reject ordering.
- `test/statifier/interpreter/content_test.exs` - the parameterized
  conversion: `:communication` raises `error.communication` with `sendid`,
  `:execution` still raises `error.execution`, and the block aborts in both.
- `test/statifier/session/recording_test.exs` and
  `test/statifier/replay_test.exs` - the widened entries and the re-supply.
- `test/statifier/replay_round_trip_test.exs` - a run whose core rejects a
  send for unreachability round-trips; a run whose *residual* path raises
  round-trips too.
- `test/statifier/session_test.exs` / `session_runtime_test.exs` - the
  end-to-end position and block abort, self-addressing, a live peer, and the
  post-stamping death that still takes the residual path.

Sabotage discipline applies to every new test above: break the code it
covers, confirm red, revert, and record the mutation in a one-line
`# sabotage:` comment (`.claude/wurk/implement.md`, `docs/testing.md`).
Generated corpus files under `test/scxml_tests/` and `test/scion_tests/` are
exempt and get no note - test496's file is untouched by this plan in any case.

### Manual Testing Steps:

1. Start two sessions under `Statifier.Supervisor`, note the second's
   `session_id`, and drive a document in the first that sends to
   `#_scxml_<that id>` followed by a sibling instruction: confirm the sibling
   *does* run and the peer receives the event.
2. Stop the peer, drive the same document again: confirm the sibling does not
   run and `error.communication` arrives before anything the sibling would
   have raised.
3. Start a session with `record: true`, run case 2, read the recording back
   with `Statifier.Session.recording/1`, and confirm the entries carry a
   snapshot; replay it with `Statifier.Replay.run/1` and confirm the same
   terminal configuration.
4. Drive a document whose `<send>` carries a `delay`, to an unreachable
   target: confirm it is scheduled, the block runs to completion, and the
   error arrives only at fire time.
5. Read `execute/2`, `raise_execution_error/4`, and the session's stamping
   sites against ADR-0048's decisions 1, 2, 3, and 6, one decision at a time.

## Performance Considerations

Snapshot construction enumerates `Statifier.Registry`'s keys once per
recordable input boundary - O(live sessions) per stamping. ADR-0048's
consequences accept this explicitly at today's scale and gate it with no
benchmark; the named reopen trigger is a measured embedder workload where the
enumeration is material. This plan therefore adds no benchmark and no
caching, and an implementer who is tempted to add one should read that
consequence first: a narrower or lazily-built snapshot is a new ADR, not a
plan-time optimization.

## References

- Source ADR: `docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md`
- Related ADRs: `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`,
  `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`,
  `docs/adr/0027-embedder-placed-session-runtime.md`,
  `docs/adr/0029-session-interpret-stays-public.md`,
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md`,
  `docs/adr/0046-round-on-every-core-effect.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md` (gate posture)
- Research: `docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md`
- Prior implementation to model after: `docs/plans/260815-st-dtm-replay-recorder-session-boundary.md`
- Similar implementation: `lib/statifier/machine/content/send.ex` (ADR-0047's
  arm), `lib/statifier/interpreter/content.ex` (the fatal channel)
- Bead: `st-72dn`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      here vacuously: no Appendix D procedure is touched, and the reviewer
      confirms that by inspection of the diff
- [ ] `Routes.reachable?/2`'s clause set is read against ADR-0048 decision 1's
      "the check covers every route the snapshot can answer - `{:session, sid}`,
      `:parent`, and `{:invoke, invokeid}` - one rule, not a test496-shaped
      special case"
- [ ] Each sabotage note was actually verified red, not written from belief

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] The touched functions match the W3C Appendix D pseudocode line for line;
      specifically `executeContent`'s block semantics in
      `Statifier.Interpreter.Content` are unchanged in structure - only the
      name the conversion raises is now a parameter
- [ ] The 4.9 quote in the moduledoc still describes what the code does, read
      against the local spec cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
      not from memory
- [ ] `Statifier.Machine.Content.Send` still names no `error.*` string
      anywhere (grep the file), and AC3's widened sweep is what proves it
      rather than the grep alone
- [ ] Each sabotage note was actually verified red

**Implementation Note**: Use `mix quality --profile loop` between edits and
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
