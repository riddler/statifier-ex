---
date: 2026-08-15
planner: Claude
branch: st-dtm-replay-recorder
repository: statifier-ex
beads_issue: st-dtm
topic: "The replay recorder at the Statifier.Session input boundary, and the replayer that proves it round-trips"
status: draft
---

# Replay recorder at the session input boundary Implementation Plan

## Overview

Build the replay recorder ADR-0029 obligated and the replayer that proves it
round-trips: a pure recording value threaded on `Statifier.Session`'s state,
appended at the five input clauses that make up the session boundary, plus a
pure replayer that re-drives the core from a recording and reproduces the
original run's effect stream and terminal snapshot. Bead: st-dtm.

The research for this bead left seven open questions. This plan settles all
seven; the two that are architectural - how replay avoids re-arming the timers
it is replaying, and whether the recording reads a clock - are settled in an
ADR (Phase 1) rather than only here, because both are decisions a later reader
will need the reasoning for.

## Current State Analysis

`docs/observability.md` constraint 6 promises deterministic replay, and
ADR-0029 fixed what a sound recording must contain (machine, initial data,
external event log, `interpret/2` batches). Nothing records. Constraint 6 is
today a constraint on code shape with no consumer.

What exists, from `docs/research/260815-st-dtm-replay-recorder-session-boundary.md`:

- **The boundary is five clauses in one module.** `init/1`
  (`lib/statifier/session.ex:289-307`), `handle_cast({:enqueue_event, _})`
  (`:363-365`), `handle_cast(:enqueue_cancel, _)` (`:367-369`),
  `handle_cast({:interpret, _})` (`:371-373`), and
  `handle_info({:statifier_delayed_send, ...})` (`:383-392`). Every other
  client function (`snapshot/1`, `status/1`, `session_id/1`, `subscribe/2`,
  `unsubscribe/2`) is a call that does not move the core.
- **The tap cannot be the inbox and cannot be a subscriber.**
  `Session.Effects.plan/1` turns a targetless `:send` into
  `{:enqueue_event, event}` (`lib/statifier/session/effects.ex:50-52`), which
  `perform_instruction/3` performs with the very same
  `Inbox.enqueue_event/2` call a caller's `send_event/2` makes
  (`lib/statifier/session.ex:472-474`). The inbox therefore holds delivered,
  derived, and timer-fired events indistinguishably, which is exactly
  ADR-0029's argument against the subscriber stream, reaching one level
  further in. The five clauses above are the tap.
- **The core is deterministic except for one value.** The session id, when
  `:session_id` is omitted, is `UXID.generate!(prefix: "sess")`
  (`lib/statifier/machine_state.ex:386`). Invoke ids are a pure counter by
  deliberate choice (`lib/statifier/interpreter.ex:1362-1406`), step counters
  are pure (`lib/statifier/machine_state.ex:601-631`, ADR-0020), events carry
  no timestamp or id (`lib/statifier/event.ex:44-56`), and no effect field is
  derived from wall-clock time.
- **Nothing in `lib/` reads a clock.** The only non-pure calls in the whole
  library are `make_ref/0` and `Process.send_after/3` at
  `lib/statifier/session.ex:483-494`, plus `Process.cancel_timer/1` and
  `Process.monitor/1`.
- **The gate constrains placement.** `Mix.Statifier.AdrGuard` treats
  `use GenServer`, `Process.send_after(`, `File.`, `spawn`, `receive do` and
  friends as findings anywhere under `lib/statifier/`
  (`lib/mix/statifier/adr_guard.ex:93-98`), allowlisting exactly one path:
  `lib/statifier/session.ex` (`:74`). A pure value threaded on
  `Session.State`, shaped like `Inbox` and `Timers`, passes untouched.
- **The re-scheduling seam is real, and nothing in the code today resolves
  it** (Decision 1 below is this plan's resolution). Re-injecting a recorded
  `interpret/2` batch containing `{:send_delayed, ...}` into a live session
  plans to `{:schedule, ...}` (`lib/statifier/session/effects.ex:58-60`) and
  arms a real timer (`lib/statifier/session.ex:483-494`), while the recording
  also holds the original firing as a log entry. The replayed run would
  receive that event twice.

### Key Discoveries:

- `lib/statifier/session.ex:377-381` already names the three converging event
  paths and calls the drain "the one recordable input path" - the property the
  recorder needs, and the reason it must attach above the inbox.
- `lib/statifier/session.ex:300` reads the resolved session id off
  `machine_state.datamodel["_sessionid"]`, so a recorder has the resolved id
  in hand at `init/1` even when the caller supplied none.
- `Statifier.Session.Inbox` and `Statifier.Session.Timers` are `@opaque t`
  structs held on `Session.State` with `@enforce_keys`
  (`lib/statifier/session.ex:112-137`), each with a colocated unit test. A
  recording threaded the same way is a fourth such field, and
  `test/statifier/session/recording_test.exs` is the naming precedent.
- `test/statifier/session_test.exs:125` pins `session_id: "sess_fixed"` - the
  existing precedent for fixing the one nondeterministic input.
- No existing test compares two runs; the round-trip shape is new
  (`test/statifier/session_test.exs:92-101` is the closest, and compares one
  run against one direct call).
- Every existing `interpret/2` call site passes a one-element list
  (`test/statifier/session_test.exs:322` and eight beside it). A multi-effect
  batch has no precedent and this plan adds one.
- ADR-0029 (`docs/adr/0029-session-interpret-stays-public.md:85-95`) leaves
  "session option or cooperating wrapper" to this bead, and names what would
  reopen it (`:117-122`): input-side recording being unable to capture
  `interpret/2` batches without a forbidden session-side change. This plan
  does not meet that condition - the batch is a plain term arriving on a cast
  clause, and the session-side change is a value append, not a routing change.
- ADR-0018 bars process jargon from code comments and the gate enforces it on
  added lines; the new comments in this work are subject to it.
- `.doctor.exs` holds 100% thresholds, so every new module needs a
  `@moduledoc` and every new public function a `@doc` and `@spec`.

## Desired End State

- `Statifier.Session.Recording` is a pure `@opaque` struct holding the four
  inputs in serialized order, with no pid, ref, port, or fun anywhere in it -
  provable by `:erlang.term_to_binary/1` round-tripping it.
- `Statifier.Session.start_link/2` takes `record: true`; `Session.recording/1`
  returns `{:ok, %Recording{}}` for a recording session and
  `{:error, :not_recording}` otherwise.
- `Statifier.Replay.run/1` takes a `%Recording{}` and returns
  `{:ok, %{machine_state: MachineState.t(), stream: [message], status: atom}}`
  or `{:error, reason}`, driving the pure core and `Session.Effects.plan/1`
  with no process and no timer.
- A test records a live run that used `interpret/2` and one that did not,
  replays each, and asserts the replayed `stream` equals the live run's
  subscriber messages (envelope stripped) and the replayed `machine_state`
  equals `Session.snapshot/1`'s.
- `docs/observability.md` constraint 6 no longer promises "session
  timestamps", and cites the new ADR for why.
- ADR-0033 records the two architectural decisions and joins the
  `docs/adr/README.md` table.

Verify with a full `mix quality` and by reading the round-trip test's
assertions: they are the acceptance criteria in executable form.

## What We're NOT Doing

- **Not replaying through a live `Statifier.Session`.** See "Decision 1"
  below. In particular, no `:replay` mode flag on the session that suppresses
  `{:schedule, ...}`: that would fork the one I/O module for a case only
  replay reaches, and it would still be replacing the performing half - just
  less honestly, and in production code.
- **No persistence, no wire format, no serialization layer.** The recording is
  an in-memory term. That it *is* serializable is asserted (a
  `term_to_binary/binary_to_term` round trip), because that property is what a
  later persistence bead needs preserved; choosing a format is that bead's
  work, and there is no serialization layer in the repo to extend.
- **No clock, no timestamps.** See "Decision 2".
- **No telemetry bridge, no debugger, no stepper.** Constraint 6's observation
  half and `docs/observability.md`'s non-goals are untouched.
- **No `<send>`/`<invoke>` producer work.** Today every `:send_delayed` and
  `:cancel` in a live session arrives through `interpret/2`
  (`lib/statifier/effect.ex:47-48`); when st-cmq.3 gives them a document-side
  producer, they arrive as core-derived effects and the recorder needs no
  change, because it taps inputs and a document-derived send is not an input.
- **No corpus or ratchet movement.** Nothing here changes conformance
  results, so `mix test.regression` is a no-change check rather than a step
  with a baseline to add.
- **Not recording `subscribe/2`, `unsubscribe/2`, `snapshot/1`, `status/1`,
  `session_id/1`, or `stop/2`.** They cross the boundary without moving the
  core (research open question 6). A recording ends where the process does.

## Implementation Approach

Four decisions settle the research's open questions. They are stated here and,
for the first two, on the record in ADR-0033.

**Decision 1 (research Q2 - the sharp one): replay re-drives the pure core and
`Session.Effects.plan/1` directly, with no process and no timer.**

`Statifier.Replay` is a pure fold over the recording's entries. It reuses
`Interpreter.initialize/2`, `Interpreter.handle_event/2`,
`Interpreter.cancel/1`, `Session.Effects.plan/1`, and `Session.Inbox` - which
is to say every deciding component the live session uses, unchanged. What it
does not reuse is the three `perform_instruction/3` clauses that touch the
process: `{:schedule, ...}` (which calls `Process.send_after/3`),
`{:notify, ...}` and `{:unroutable, ...}` (which `send/2` to subscribers).
Replay records those instead of performing them.

The rationale, in three parts:

1. **It dissolves the double-delivery seam rather than patching it.** The
   seam exists only because arming a real timer is a wall-clock act. A
   replayer that never arms one receives each recorded firing exactly once,
   at its recorded position - which is precisely the bead's "reproduce firing
   order and relative timing, not re-wait the delays".
2. **The part replay replaces is exactly the nondeterministic part.** The
   split between deciding and performing is not incidental here - it is the
   split `lib/statifier/session.ex:8-14` was written to make, and ADR-0003 is
   its warrant. Everything above that line is reused byte for byte;
   everything below it is what a replay must not do.
3. **The alternatives cost more.** A `:replay` mode inside `Session` puts a
   permanent test-shaped branch in the one allowlisted I/O module and still
   replaces the performing half. Cancelling each re-armed timer on injection
   is a race by construction - a short delay can fire before the cancel is
   performed - and it would additionally emit `{:cancel, ...}` planning that
   the original run never had, corrupting the compared stream.

The honest cost is drift: `Replay`'s instruction handling could diverge from
`Session`'s. Two mitigations, both in this plan. The round-trip test compares
a live run against a replayed one, so any divergence in the deciding half
reddens the gate immediately (Phase 5). And `Replay`'s instruction fold
matches on `Session.Effects.instruction()` with no catch-all clause, so a new
instruction kind is a `FunctionClauseError` at the first test that produces
one rather than a silent skip.

Replay also gains a check the live session cannot make: a recorded timer
firing whose `send_id` is not live in Replay's own pending-timer bookkeeping
means the recording is inconsistent with the machine it is being replayed
against. That returns `{:error, {:unscheduled_timer_firing, send_id}}` rather
than proceeding, which turns the one class of silent divergence replay could
otherwise produce into a loud one.

That check has to account for one legitimate case, or it rejects recordings a
live session can honestly produce. `Process.cancel_timer/1` returns `false`
when the delay has already elapsed and the `{:statifier_delayed_send, ...}`
message is already waiting: the cancel does not unsend it, and
`handle_info/2` enqueues it unconditionally
(`lib/statifier/session.ex:383-392`). So a recording can legitimately hold a
`{:timer, send_id, event}` entry *after* the `{:cancel, ...}` effect that
cancelled that id. Replay mirrors it rather than rejecting it: a
`{:cancel_timers, send_id}` instruction does not simply delete the key, it
moves that id's pending count to a second `raced` map. A firing draws credit
from `pending` first and from `raced` second, and is delivered normally in
either case - which is exactly what the live session did. Only a firing with
credit in neither map is the inconsistency the error names. This keeps the
check sharp (a fabricated or mismatched firing still errors) without making
it reject a real recording, and it is the single place replay must model a
mechanic of `Process.cancel_timer/1` rather than of the core.

**Decision 2 (research Q1): the recording carries ordinal order, no clock.**

Entry position in the list is the whole of the ordering information, and it is
sufficient: the bead requires firing *order*, and forbids re-waiting delays.
Relative timing is not lost either - it is derivable, since each firing's
originating `delay_ms` is already in the recording, on the `:send_delayed`
effect inside the `interpret/2` batch (or, later, inside a core-derived
batch). Recording a real timestamp would introduce the library's first clock
read, on the one path the ADR guard allowlists, to store a value replay must
then ignore. `docs/observability.md:154`'s "with session timestamps" is
amended to "in the session's serialized input order" in Phase 1.

**Decision 3 (research Q3, Q4, Q6, Q7): the recording's shape and placement.**

- **Placement**: `Statifier.Session.Recording`, a pure `@opaque` struct held
  as a fifth field on `Session.State`, appended at the five input clauses -
  the `Inbox`/`Timers` shape exactly, so `Mix.Statifier.AdrGuard` has nothing
  to flag and there is no argument to make. Enabled by `record: true` on
  `start_link/2`, off by default; when off the field is `nil` and each input
  clause skips one function call.
- **Entries** (research Q7): `{:event, Event.t()}`, `:cancel`,
  `{:timer, send_id, Event.t()}`, and `{:interpret, [Effect.t()]}`. **Batch
  boundaries are load-bearing and preserved.** One `interpret/2` call is one
  `perform/3` whose whole instruction list runs before the next
  `{:continue, :drain}`, so flattening two batches into one would change how
  their effects interleave with draining. The fired timer's correlation `ref`
  is dropped - it is the one non-serializable term at the boundary
  (`lib/statifier/session.ex:484`), and it is a within-run correlation id with
  no meaning in a second run.
- **Initial data** (research Q4): the recording captures `:trace`,
  `:datamodel`, and `:max_macrostep_rounds` as supplied (defaults applied),
  and `:session_id` **resolved** - read off
  `machine_state.datamodel["_sessionid"]` whether the caller supplied it or
  not. That closes the single nondeterminism. The consequence is stated in the
  `@doc`: a recording's initial data is the resolved option set, not a
  transcript of the caller's keyword list. `:datamodel` is captured as
  supplied rather than post-merge, because `MachineState.new/2` merges
  `SystemVariables.initial/2` *over* it (`lib/statifier/machine_state.ex:398`)
  and replay re-runs that merge.
- **Not recorded** (research Q6): the non-mutating calls and `stop/2`.

**Decision 4 (research Q5): what "the effect stream matches" means.**

`Replay.run/1` returns a `stream` of `{:effect, effect} | {:unroutable,
effect} | {:halted, reason}` - the subscriber message shapes with the
`{:statifier, session_id, _}` envelope stripped. The comparison is list
equality against the live run's collected subscriber messages, envelope
stripped. `{:unroutable, _}` and `{:halted, _}` are included rather than
dropped: they are not effects, but they are deterministic functions of the
effect stream under `Effects.plan/1`, so including them makes the assertion
strictly stronger at no cost. `:trace` is fixed identically on both sides by
construction, since it is one of the recorded initial-data options.

The terminal snapshot comparison is `%MachineState{}` equality between
`Session.snapshot/1` and `Replay.run/1`'s `machine_state`. Both sides have
`exit_interpreter/1`'s configuration emptying applied identically, so the
`%Effect.Done{}` reading `status/1` performs
(`lib/statifier/session.ex:553-571`) is not needed for the comparison; the
replay result carries `status` separately for callers that want it.

**Known accepted risk**: `MapSet.to_list/1` on history-recorded states
(`lib/statifier/interpreter/exit_entry.ex:465`,
`lib/statifier/interpreter/selection.ex:128`) feeds entry ordering and is not
an explicit document-order sort. Iteration order is a function of set contents
on a given BEAM build, so two runs in one test process agree. A recording
replayed on a different OTP release could in principle differ. That is a
pre-existing property of the interpreter, not something this work introduces,
and fixing it is an interpreter change out of scope here; ADR-0033's
Consequences name it so the next reader finds it stated rather than
rediscovers it.

## Phase 1: Record the decision (ADR-0033) and amend constraint 6

### Overview

Put Decisions 1 and 2 on the record before the code that assumes them, and
retire `docs/observability.md`'s unmet timestamp promise. Documentation only -
no Elixir changes, so this phase has no test to write and no coverage to move.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0033-replay-re-drives-the-core-not-a-live-session.md`
**Changes**: New record in the three-section format (Context, Decision,
Consequences) the ADR README requires.

Context: constraint 6 and ADR-0029 obligate a recorder; st-dtm's research
found the re-scheduling seam and the absent clock. Decision, in two numbered
parts:

1. Replay re-drives the pure core and `Session.Effects.plan/1` with no
   process and no timer; it is not a live `Statifier.Session`, and the session
   gains no replay mode. Carries the three-part rationale and the two
   rejected alternatives from "Decision 1" above, plus the drift mitigation.
2. The recording carries ordinal order and no clock reading. Carries
   "Decision 2" above, including that relative timing stays derivable from
   the recorded `delay_ms`.

Consequences: constraint 6 amended; `Statifier.Replay` is public API with the
round-trip test as its proof; the `MapSet.to_list/1` ordering caveat is named
as an accepted, pre-existing risk; the `Process.cancel_timer/1` cancel/fire
race is named as the one live-runtime mechanic replay has to model rather than
reuse, with the `raced` credit map as how; what would reopen the record is a replay
requirement that genuinely needs the performing half exercised (a timer bug
reproducible only through `Process.send_after/3`), which would be argued
there rather than patched around.

If `0033` is taken by a branch that lands first, take the next free number -
this plan's references are by title.

#### 2. The ADR index

**File**: `docs/adr/README.md`
**Changes**: One table row for the new record, `accepted`.

#### 3. Constraint 6

**File**: `docs/observability.md`
**Changes**: In the Replay bullet (`:151-165`), replace "delivered events,
timer firings, with session timestamps" with the ordinal-order form, and cite
the new ADR beside ADR-0029. Replace "The recorder itself is unbuilt
(st-dtm)" once Phase 5 lands - not here, so this phase stays honest about what
exists at the moment it commits.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating).
- [x] `mix quality --profile merge` passes, which is what actually runs the
      ADR judge stage - the bare gate skips it by design
      (`.quality.exs:23`), so a bare green does not exercise the new record.
- [x] `mix quality --format json --report -` is green - every phase advances
      under `/wurk:commit --auto` in a `--loop` run, which routes on that
      output, so it is a criterion of each phase and not only the last.
- [x] `grep -c '^## ' docs/adr/0033-*.md` returns 3, and
      `grep -c '0033-' docs/adr/README.md` returns at least 1.

#### Manual Verification:
- [ ] The ADR's Decision section states the position, not the plan's summary
      of it: a reader who has never seen this plan can tell why replay is not
      a live session.
- [ ] `docs/observability.md` no longer promises anything the code will not
      deliver at the end of this plan.

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full gate as the phase gate. This phase touches no Elixir, so per CLAUDE.md it
could commit on review of the diff alone; run the gate anyway, since the ADR
judge is the point of the phase.

---

## Phase 2: `Statifier.Session.Recording`, the pure value

### Overview

The recording struct and its pure append/read functions, with a colocated unit
test. Nothing consumes it yet, but the unit test exercises it completely, so
the phase stands on its own gate.

### Changes Required:

#### 1. The module

**File**: `lib/statifier/session/recording.ex`
**Changes**: New pure module, `Inbox`/`Timers` in shape.

```
defmodule Statifier.Session.Recording do
  @moduledoc """
  The four-input replay recording (ADR-0029), as a value.
  ...
  """

  @enforce_keys [:machine, :opts, :entries]
  defstruct [:machine, :opts, entries: []]

  @typedoc "One recorded input, in the session's serialized input order."
  @type entry ::
          {:event, Event.t()}
          | :cancel
          | {:timer, send_id :: String.t() | nil, Event.t()}
          | {:interpret, [Effect.t()]}

  @opaque t :: %__MODULE__{
            machine: Machine.t(),
            opts: keyword(),
            entries: [entry()]
          }

  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  @spec put_event(t(), Event.t()) :: t()
  @spec put_cancel(t()) :: t()
  @spec put_timer(t(), send_id :: String.t() | nil, Event.t()) :: t()
  @spec put_interpret(t(), [Effect.t()]) :: t()
  @spec machine(t()) :: Machine.t()
  @spec opts(t()) :: keyword()
  @spec entries(t()) :: [entry()]
  @spec size(t()) :: non_neg_integer()
end
```

`entries` is stored reversed and reversed on read, so each append is O(1) - a
session that never reads its recording pays one cons per input. `opts` is
normalized at `new/2` to exactly `[:session_id, :trace, :datamodel,
:max_macrostep_rounds]` with defaults applied and `:session_id` resolved,
sorted so two recordings of the same run compare equal.

The moduledoc states: the four inputs and which is which; that batch
boundaries are preserved and why; that the timer `ref` is dropped and why;
that `:session_id` is the resolved value, not the supplied one; and that
nothing here reads a clock, citing the new ADR. ADR-0018 applies to every
comment added.

#### 2. The unit test

**File**: `test/statifier/session/recording_test.exs`
**Changes**: New. Covers: `new/2` normalizes and defaults the four options;
`new/2` errors nothing and simply resolves when `:session_id` is given;
entries come back in append order across all four kinds interleaved; a
multi-effect `interpret/2` batch stays one entry; `size/1` counts entries;
`term_to_binary/binary_to_term` round-trips a populated recording to an equal
term.

Every test carries its sabotage line per `docs/testing.md`, naming the exact
mutation, e.g.
`# sabotage: entries/1 drops the Enum.reverse -> the append-order assertion reddens`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix quality --format json --report -` is green (see Phase 1's note on
      why this is a per-phase criterion).
- [x] `mix test test/statifier/session/recording_test.exs` passes.
- [x] Doctor's 100% thresholds hold - every public function has `@doc` and
      `@spec`, the module has a `@moduledoc`.
- [x] `mix adr.check` reports no finding on the new file (it is pure; a
      finding here means something process-shaped got in).

#### Manual Verification:
- [ ] The moduledoc answers, without the plan in hand, why a batch is one
      entry and why the timer ref is absent.
- [ ] Each sabotage line names a mutation that would actually redden the test
      beside it (this phase touches no interpreter function, so the Appendix D
      line-for-line criterion does not apply).

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate. Under `--loop`, the automated list gates advancement and the
manual items are deferred.

---

## Phase 3: Wire the recorder into `Statifier.Session`

### Overview

The `record: true` option, the fifth `Session.State` field, the appends at the
five input clauses, and `Session.recording/1`. This is the only phase that
touches the allowlisted I/O module.

### Changes Required:

#### 1. The session

**File**: `lib/statifier/session.ex`
**Changes**:

- `State`: add `recording: nil` to `defstruct` and `Statifier.Session.Recording.t() | nil`
  to `@type t`. Not in `@enforce_keys` - `nil` is the default and the common
  case.
- `init/1`: after `machine_state` is built and the session id read at `:300`,
  build the recording when `Keyword.get(opts, :record, false)`:
  `Recording.new(machine, Keyword.put(machine_opts, :session_id, session_id))`.
  `:record` is dropped from what reaches `MachineState.new/2` - `machine_opts`
  is already a `Keyword.take/2` of exactly four keys, so this is automatic.
- `handle_cast({:enqueue_event, event}, state)`: `Recording.put_event/2`.
- `handle_cast(:enqueue_cancel, state)`: `Recording.put_cancel/1`.
- `handle_cast({:interpret, effects}, state)`: `Recording.put_interpret/2`,
  **before** `perform/2` - the entry records the input, not its outcome.
- `handle_info({:statifier_delayed_send, ref, send_id, event}, state)`:
  `Recording.put_timer/3` with `send_id` and `event`, dropping `ref`. Note
  that `send_id` is currently ignored here (`_send_id`); it stops being
  ignored.
- One private `record/2` helper doing the `nil` check, so each clause gains
  one line rather than a `case`.
- `recording/1`: a new `GenServer.call` returning `{:ok, Recording.t()}` or
  `{:error, :not_recording}`, with a `@doc` stating that it must be called
  after the run has quiesced, since a timer firing is a message the caller
  has no ordering guarantee against.
- `start_link/2`'s `@doc`: document `:record`.
- The moduledoc: a short section on recording, citing ADR-0029 and the new
  ADR, and stating that the tap is the input clauses and never the inbox -
  the reason being the converging-paths comment already at `:377-381`.

The appends are the only session-side change. No routing changes, no new
instruction kind, nothing that touches `Effects.plan/1` - so ADR-0029's
reopening condition (`:117-122`) is not met, and this phase should say so in
its commit body rather than leaving a reader to check.

#### 2. The session test

**File**: `test/statifier/session_test.exs`
**Changes**: A new `describe "recording"` block. Covers: `recording/1` returns
`{:error, :not_recording}` by default; with `record: true`, a run driven by
`send_event/2` records those events in order; `cancel/1` records the cancel
marker in queue position relative to events; an `interpret/2` call records its
batch; a fired delayed send records a `{:timer, send_id, event}` entry after
the `interpret/2` entry that scheduled it; the recorded `opts` carry the
resolved session id when none was supplied. Timer tests wait on the subscriber
(`assert_receive`) or `wait_for_status/3` before calling `recording/1`, per the
`@doc`'s ordering caveat.

Sabotage lines throughout, e.g.
`# sabotage: handle_cast({:interpret, _}) records after perform/2 -> the entry order assertion against the timer firing reddens`.

#### 3. Changelog fragment

**File**: `changelog.d/st-dtm.md`
**Changes**: New. `record: true` and `Session.recording/1` are a public API
addition, which `changelog.d/README.md` lists as fragment-worthy.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix quality --format json --report -` is green (see Phase 1's note on
      why this is a per-phase criterion).
- [x] `mix test test/statifier/session_test.exs` passes, including the
      existing suites - the appends must not perturb them.
- [x] `mix adr.check` reports no new finding on `lib/statifier/session.ex`
      (the file is allowlisted for I/O, but ADR-0018 still applies to the
      comments this phase adds).
- [x] `mix test.regression` is unchanged - no conformance result moves, so
      `test/passing_tests.json` needs no `mix test.baseline add`.
- [x] `changelog.d/st-dtm.md` exists.

#### Manual Verification:
- [ ] A session started without `record: true` is unchanged in behavior and
      pays only a `nil` check per input.
- [ ] The recorded entry order for a run mixing all four input kinds matches
      the order the inputs were actually issued in, read by eye off the test.
- [ ] Spec conformance: this phase adds no interpreter logic - the drain loop,
      `drain_event/2`, and `drain_cancel/1` are untouched, so Appendix D's
      `mainEventLoop` port is line-for-line what it was. Confirm by diff that
      no line inside those functions changed.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate.

---

## Phase 4: `Statifier.Replay`, the pure replayer

### Overview

The replayer: a pure fold over a recording's entries that mirrors the
session's drain loop and instruction performance without a process or a timer.
Unit-tested against hand-built recordings, so it stands on its own gate before
Phase 5 points a live run at it.

### Changes Required:

#### 1. The module

**File**: `lib/statifier/replay.ex`
**Changes**: New pure module.

```
defmodule Statifier.Replay do
  @moduledoc """
  Re-drives a `Statifier.Session.Recording` through the pure core, with no
  process and no timer (ADR-0033).
  ...
  """

  @typedoc "One replayed stream message - the subscriber shapes, envelope stripped."
  @type message ::
          {:effect, Effect.t()} | {:unroutable, Effect.t()} | {:halted, halt_reason()}

  @type result :: %{
          machine_state: MachineState.t(),
          stream: [message()],
          status: :running | :done | :cancelled | :budget_exhausted
        }

  @spec run(recording :: Recording.t()) ::
          {:ok, result()} | {:error, {:unscheduled_timer_firing, String.t() | nil}}
end
```

The fold:

- Start: `Interpreter.initialize(Recording.machine(r), Recording.opts(r))`,
  then `perform` the returned effects, then `drain`.
- Each entry: `{:event, e}` enqueues on `Session.Inbox` and drains;
  `:cancel` enqueues the cancel marker and drains; `{:interpret, effects}`
  performs the batch and drains; `{:timer, send_id, e}` draws one credit for
  `send_id` - from `pending` first, from `raced` second - then enqueues and
  drains, or returns `{:error, {:unscheduled_timer_firing, send_id}}` when
  neither map has credit under that id.
- `drain` mirrors `handle_continue(:drain, _)` exactly, halted rules included:
  a `:cancel` entry is always drained; an ordinary event is left queued while
  halted.
- `perform` mirrors `perform/3` and `perform_instruction/3`, one clause per
  `Session.Effects.instruction()`, **no catch-all**:
  `{:notify, effect}` appends `{:effect, effect}` to the stream (and retains
  the `%Done{}`); `{:enqueue_event, e}` enqueues; `{:schedule, send_id, _delay,
  _event}` increments `pending[send_id]` and arms nothing;
  `{:cancel_timers, send_id}` moves `pending[send_id]` into `raced[send_id]`
  rather than dropping it, per the cancel/fire race in Decision 1;
  `{:unroutable, effect}` appends;
  `{:halt, reason}` sets the halt with the same `:cancelled` override the
  cancel drain applies, and appends `{:halted, reason}`.
- Pending timers are two plain `%{send_id => non_neg_integer()}` count maps
  (`pending` and `raced`), not `Session.Timers`: `Timers` is keyed by
  `reference()`, and minting refs would be an impure call in a module whose
  whole claim is purity. Counts are sufficient because replay never cancels a
  real timer and never correlates a firing to a specific arming - spec 6.3's
  "cancel them all" is a whole-key move either way. `nil` is a legitimate key
  (a delayed send with no id).

The moduledoc states the reuse boundary explicitly: which session components
are reused unchanged, which three `perform_instruction/3` clauses are
replaced, and why that is the nondeterministic half by construction (ADR-0033,
ADR-0003).

#### 2. The unit test

**File**: `test/statifier/replay_test.exs`
**Changes**: New, over recordings built directly with
`Statifier.Session.Recording` functions - no live session, so this phase's
tests do not depend on Phase 3's wiring being right.

Covers: an empty recording replays to the post-`initialize/2` state; an event
entry advances the configuration; a cancel entry halts `:cancelled` and emits
`{:halted, :cancelled}`; an `interpret/2` batch containing a targetless
`:send` re-enqueues and drains; a batch containing `:send_delayed` followed by
its `{:timer, ...}` entry delivers the event exactly once; a `:cancel` effect
for that same send id followed by that id's `{:timer, ...}` entry delivers the
event (the cancel/fire race - `raced` credit, not an error); a `{:timer, ...}`
entry for a send id nothing ever scheduled returns
`{:error, {:unscheduled_timer_firing, _}}`; an ordinary event entry after a
halt stays queued and produces no further stream messages; a multi-effect
batch of unrelated kinds preserves effect order in the stream.

The single-delivery test is the one that proves Decision 1; its sabotage line
says so, e.g.
`# sabotage: the {:schedule, ...} clause enqueues the event instead of counting it -> the event is delivered twice and the stream assertion reddens`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix quality --format json --report -` is green (see Phase 1's note on
      why this is a per-phase criterion).
- [x] `mix test test/statifier/replay_test.exs` passes.
- [x] `mix adr.check` reports no finding on `lib/statifier/replay.ex` - the
      module is pure, so any finding is a design escape, not a comment to
      write.
- [x] Doctor's 100% thresholds hold for the new module.

#### Manual Verification:
- [ ] Read `Replay`'s `perform` clauses against `Session`'s
      `perform_instruction/3` clauses side by side: the four non-process
      clauses agree, and the three replaced ones are replaced for the reason
      the moduledoc gives.
- [ ] Read `Replay`'s `drain` against `handle_continue(:drain, _)` at
      `lib/statifier/session.ex:317-333`: the halted rules agree, including
      that a cancel is always drained.
- [ ] Spec conformance: `Replay` calls the Appendix D functions rather than
      reimplementing any of them - confirm no pseudocode-named function is
      duplicated in the new module. The drain loop it does mirror is the
      session's port of `mainEventLoop`'s dequeue tail, and the criterion is
      that it matches that port line for line.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate.

---

## Phase 5: The round-trip proof

### Overview

st-dtm's acceptance criteria, executable: record a live run, replay it, assert
the streams and terminal snapshots match - once for a run that used
`interpret/2` and once for one that did not.

### Changes Required:

#### 1. The round-trip test

**File**: `test/statifier/replay_round_trip_test.exs`
**Changes**: New. A helper drives a live recording session with
`subscribers: [self()]`, collects every `{:statifier, session_id, message}` it
receives (draining the mailbox after quiescence), strips the envelope, reads
`Session.recording/1` and `Session.snapshot/1`, then runs
`Statifier.Replay.run/1` and asserts both `stream` equality and
`%MachineState{}` equality.

Four cases:

1. **No `interpret/2`.** A document that reaches a stable configuration, then
   two `send_event/2` calls that move it, then natural termination. ADR-0029's
   "the fourth input is empty" case - assert the recording holds no
   `{:interpret, _}` entry.
2. **With `interpret/2`.** A run whose batch contains a targetless
   `:send_delayed` plus a `:log`, followed by the timer firing, followed by an
   event. This is the case Decision 1 exists for: the recording holds both the
   scheduling batch and the firing, and the replay must deliver the event once.
3. **A multi-effect batch.** One `interpret/2` call carrying several unrelated
   effect kinds, which has no precedent in the suite today - proves batch
   boundaries survive.
4. **A `cancel/1` run.** Cancel queued behind events, halting `:cancelled`,
   with the terminal snapshot compared after `exit_interpreter/1` has emptied
   the configuration on both sides.

Both runs pin `trace: true` so the trace effects join the compared stream, and
neither pins `:session_id` - the point is that the recording resolves it. One
additional case pins `session_id: "sess_fixed"` and asserts the recorded
`opts` carry that value unchanged, so both branches of Decision 3's session-id
rule are covered.

Sabotage lines per case; the case-2 line names the double-delivery mutation
directly.

#### 2. Documentation close-out

**File**: `docs/observability.md`
**Changes**: The Replay bullet's "The recorder itself is unbuilt (st-dtm)"
sentence becomes a pointer to `Statifier.Session.Recording` and
`Statifier.Replay`. The "it cannot be a subscriber" clause stays - it is still
the reason for the design, not a status note.

**File**: `changelog.d/st-dtm.md`
**Changes**: Extend the Phase 3 fragment with `Statifier.Replay`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix test test/statifier/replay_round_trip_test.exs` passes, and all
      four cases assert both stream equality and terminal-snapshot equality.
- [x] `mix quality --format json --report -` is green (see Phase 1's note on
      why this is a per-phase criterion).
- [x] `mix test.regression` unchanged.
- [x] `mix quality --profile merge` passes before the branch is published, so
      the ADR judge sees the whole change including Phase 1's record.
- [x] `mix gate.verify` exits zero, proving the reported green was a full,
      unscoped, un-`--skip`-ed run.

#### Manual Verification:
- [ ] Case 2's assertion actually distinguishes single from double delivery -
      confirm by reading the expected stream that the event's effects appear
      exactly once.
- [ ] `docs/observability.md` constraint 6 now describes something that
      exists, end to end.
- [ ] The compared streams are non-trivial: each case's expected stream has
      more than a `{:halted, _}` in it, so equality is a real assertion rather
      than two empty lists.
- [ ] Spec conformance: no interpreter function changed in this phase, so the
      Appendix D port is untouched - confirm by diff.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate. This is the last phase; the deferred manual items from
Phases 1-4 surface here under `--loop`.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/session/recording_test.exs` - the pure value: normalization
  and defaulting of the four options, append order across all four entry
  kinds, batch boundaries preserved, `term_to_binary` round trip.
- `test/statifier/session_test.exs` (new `describe`) - the tap: each of the
  five input clauses records the right entry, in the right position, and only
  when `record: true`.
- `test/statifier/replay_test.exs` - the replayer over hand-built recordings:
  the drain loop's halted rules, the four non-process instruction clauses, the
  three replaced ones, and the `{:error, {:unscheduled_timer_firing, _}}`
  path.
- `test/statifier/replay_round_trip_test.exs` - the acceptance criteria.

Key edge cases: an ordinary event recorded after a halt (queued, never
drained, still recorded); a delayed send with `send_id: nil`; a `:cancel`
effect that removes a pending timer before its firing could be recorded; the
cancel/fire race, where the firing is recorded anyway and replay must deliver
it from `raced` credit rather than error (unit-testable deterministically at
the `Replay` level by hand-building that entry order, which is why Phase 4
covers it rather than Phase 5 - reproducing the race against a live session
would be a timing-dependent test); a
recording whose `interpret/2` batch is empty; a session that terminates
before a scheduled timer fires (`terminate/2` cancels it, so no firing entry
exists and replay's count map simply never decrements).

Every new test asserting `lib/` behavior carries a sabotage line naming the
mutation and its consequence, per `docs/testing.md` and CLAUDE.md. None of
these files is generated-corpus, so none is exempt; the round-trip helper
itself, if it grows a plain harness function with no `lib/` assertion of its
own, states `# sabotage: n/a - ...` rather than omitting the line.

### Manual Testing Steps:

1. Start an `iex -S mix` session, compile a small document, start a session
   with `record: true, trace: true`, send it two events, and read
   `Statifier.Session.recording/1` - confirm the entries read as the inputs
   issued.
2. Feed that recording to `Statifier.Replay.run/1` and compare its `stream`
   against what a subscriber saw. Confirm they match term for term.
3. Repeat with an `interpret/2` batch carrying a `:send_delayed` with a 30 ms
   delay; wait for the firing, then replay and confirm the replay returns
   immediately (no 30 ms wait) and delivers the event once.
4. Confirm a session started without `record: true` still behaves identically
   and that `recording/1` returns `{:error, :not_recording}`.

## Corpus/Ratchet Notes

No corpus regeneration and no `test/passing_tests.json` change. Nothing in
this plan alters what any conformance document does: the recorder appends to a
value, the replayer is a new consumer, and neither is on a path a
SCION or W3C test reaches. `mix test.regression` is run each phase as a
no-change check, and `mix test.baseline add` is not run at all - if it ever
wants to be, something moved that this plan did not intend to move.

## Performance Considerations

Recording is off by default, and off costs one `nil` check per input clause.
On, each input costs one cons onto a reversed list (O(1)); reading reverses
once. The recording retains the compiled `%Machine{}` by reference, so a
recording is not a copy of the machine until it crosses a process boundary -
`recording/1` is a `GenServer.call`, so it does copy there, exactly as
`snapshot/1` already does (`lib/statifier/session.ex:247-254` notes the same
cost). That is acceptable for a debugging and replay surface called once at
the end of a run, and it is why `recording/1` is a call rather than a field on
`status/1`'s per-poll projection.

## References

- Source document: `docs/research/260815-st-dtm-replay-recorder-session-boundary.md`
- Related ADRs: `docs/adr/0029-session-interpret-stays-public.md` (the
  four-input recording and the not-a-subscriber ruling),
  `docs/adr/0003-pure-core-with-effects.md` (the deciding/performing split
  replay leans on), `docs/adr/0012-debuggability-designed-into-the-core.md`
  (makes constraint 6 binding),
  `docs/adr/0008-uxid-for-identifiers.md` (why exactly one value needs
  recording), `docs/adr/0019-macrostep-round-budget.md` and
  `docs/adr/0020-round-ordinal-joins-the-step-counters.md` (the counters two
  runs are compared on), `docs/adr/0018-no-process-jargon-in-code-comments.md`
  (binds the comments this work adds), plus the new ADR-0033 from Phase 1
- Constraint: `docs/observability.md` constraint 6 (`:145-165`)
- Similar implementation: `lib/statifier/session/inbox.ex`,
  `lib/statifier/session/timers.ex` (the pure-value-on-`State` shape),
  `lib/statifier/session/effects.ex:44-92` (the instruction vocabulary
  `Statifier.Replay` folds over), `lib/statifier/session.ex:448-512` (the
  `perform_instruction/3` clauses it mirrors)
- Test precedent: `test/statifier/session_test.exs:125` (fixed session id),
  `:300-409` (the delayed-send and cancel suites), `:596-612`
  (`wait_for_status/3`), `test/statifier/session/inbox_test.exs:10-11`
  (sabotage line form)
- Bead: `st-dtm`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

All items below were walked through and verified on 2026-08-15, after the
last phase landed. Three of them did not pass as written; what changed in
response is recorded beside each.

### Phase 1

- [x] The ADR's Decision section states the position, not the plan's summary
      of it: a reader who has never seen this plan can tell why replay is not
      a live session.
- [x] `docs/observability.md` no longer promises anything the code will not
      deliver at the end of this plan. Every artifact the Replay bullet names
      exists; the one forward-looking phrase left is the `:telemetry` bridge,
      hedged as "once it exists".

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full gate as the phase gate. This phase touches no Elixir, so per CLAUDE.md it
could commit on review of the diff alone; run the gate anyway, since the ADR
judge is the point of the phase.

---

### Phase 2

- [x] The moduledoc answers, without the plan in hand, why a batch is one
      entry and why the timer ref is absent - it carries a named section for
      each.
- [x] Each sabotage line names a mutation that would actually redden the test
      beside it (this phase touches no interpreter function, so the Appendix D
      line-for-line criterion does not apply). All seven traced through. The
      one `# sabotage: n/a` is on the term round-trip test, and the exemption
      holds: `term_to_binary/1` and `binary_to_term/1` there are Erlang's, not
      `Recording`'s, so no `lib/` mutation reddens it.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate. Under `--loop`, the automated list gates advancement and the
manual items are deferred.

---

### Phase 3

- [x] A session started without `record: true` is unchanged in behavior and
      pays only a `nil` check per input. Behavior is unchanged - `record/2`'s
      `nil` clause returns the state untouched. The cost is a shade more than
      the check, though: each call site also allocates its closure before the
      clause match decides to discard it. The comment above `record/2` said
      "only this one check" and now says what is actually paid.
- [x] The recorded entry order for a run mixing all four input kinds matches
      the order the inputs were actually issued in, read by eye off the test.
      **Did not pass as written.** No single session-level run mixed all four:
      the interleave existed only as a `Recording` unit test
      (`test/statifier/session/recording_test.exs`), with the round-trip cases
      each covering a slice (interpret + timer + event, or events + cancel).
      Case 5 of `test/statifier/replay_round_trip_test.exs` was added to drive
      all four through a live session in one run, and its entry-order
      assertion is what this item now reads off.
- [x] Spec conformance: this phase adds no interpreter logic - the drain loop,
      `drain_event/2`, and `drain_cancel/1` are untouched, so Appendix D's
      `mainEventLoop` port is line-for-line what it was. Confirmed by
      extracting all three functions from `origin/main` and from the branch
      head and comparing: byte-identical, 17/12/9 lines. No hunk on
      `lib/statifier/session.ex` falls inside any of them.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate.

---

### Phase 4

- [x] Read `Replay`'s `perform` clauses against `Session`'s
      `perform_instruction/3` clauses side by side: every divergence is one
      ADR-0033 licenses, and each replaced clause is replaced for the reason
      the moduledoc gives. **The item's own count was wrong** and is corrected
      here: it said "the four non-process clauses agree, and the three
      replaced ones are replaced". In fact only `{:enqueue_event, _}` is
      process-free and byte-identical. Six clauses diverge, each licensed:
      `{:notify, _}` (both arms) and `{:unroutable, _}` and `{:halt, _}` swap
      `notify/2` for `append/2`; `{:schedule, _, _, _}` swaps a real
      `Process.send_after/3` for a `pending` credit; `{:cancel_timers, _}`
      swaps `Process.cancel_timer/1` for the `pending` -> `raced` move that
      models the cancel/fire race.
- [x] Read `Replay`'s `drain` against `handle_continue(:drain, _)` at
      `lib/statifier/session.ex:317-333`: the halted rules agree, including
      that a cancel is always drained. Same four clauses in the same order;
      `{:event, _}` returns early when `halted != nil` on both sides.
- [x] Spec conformance: `Replay` calls the Appendix D functions rather than
      reimplementing any of them - confirmed, no pseudocode-named function is
      defined in the module, which calls `Interpreter.initialize/2`,
      `Interpreter.handle_event/2`, and `Interpreter.cancel/1`. The drain loop
      it does mirror matches the session's port of `mainEventLoop`'s dequeue
      tail clause for clause.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate.

---

### Phase 5

- [x] Case 2's assertion actually distinguishes single from double delivery.
      **Did not pass as written**, twice over: the assertion counted the batch
      log in `stream`, the *live* run's stream, where it is 1 by construction
      whatever replay does, and the comment above it described checking the
      event's own `b -> c` transition effects, which it did not. A count
      cannot make this distinction at all - a doubled delivery still ends at
      "c" with two transitions, and only the *position* of those effects
      relative to the batch's `:log` moves. The full ordered
      `result.stream == stream` comparison in `round_trip/3` is what catches
      it, which is also what the case's sabotage note already pointed at. The
      local assertion now reads off `result.stream` and the comment says what
      it is for.
- [x] `docs/observability.md` constraint 6 now describes something that
      exists, end to end: record -> `Recording.entries/1` -> `Replay.run/1` ->
      stream and snapshot equality, proven across the round-trip cases.
- [x] The compared streams are non-trivial: each case's expected stream has
      more than a `{:halted, _}` in it, so equality is a real assertion rather
      than two empty lists. Case 3 pins an exact four-message non-trace
      stream; the others assert `length(stream) > 1` beside their halt.
- [x] Spec conformance: no interpreter function changed in this phase, so the
      Appendix D port is untouched - confirmed by diff, the phase's commit
      touches `changelog.d/`, `docs/`, and one test file, with no `lib/` diff
      at all.

**Implementation Note**: `mix quality --profile loop` between edits, full gate
as the phase gate. This is the last phase; the deferred manual items from
Phases 1-4 surface here under `--loop`.

---
