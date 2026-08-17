# Re-entry Effects Defer to the Outer Batch Implementation Plan

## Overview

`Statifier.Session.deliver_internal/6` crosses the ADR-0039 seam and then
calls `perform/3` **recursively** on the effects the seam returns, so a
subscriber sees the whole re-entry before the tail of the batch that
triggered it. Arrival order is therefore non-monotone in `(macrostep,
round)`, more than one `Trace.MacrostepStable` can arrive per macrostep with
the later one carrying the *lower* round, and trace effects can arrive after
`{:halted, :done}`.

This plan implements ADR-0043 (accepted 2026-08-17): the seam is still
crossed at its instruction's position, but the effects it returns are
**enqueued** and drained FIFO by the outermost `perform/3` after its own
instruction list is exhausted. It also makes `{:halted, reason}` a promised
end-of-stream, documents the multiple-`MacrostepStable` rule with its
`(macrostep, round)` uniqueness key, and lands the three regression tests
ADR-0043's consequences name. Bead: st-r6l9.

## Current State Analysis

**The mechanism.** `perform/3` (`lib/statifier/session.ex:912-919`) plans an
effect list into instructions and reduces over them. `{:notify, effect}` is
the head of every effect's own instruction list
(`lib/statifier/session/effects.ex:112-151`), and performing it calls
`notify/2` (`lib/statifier/session.ex:1382-1386`), an unconditional `send/2`
per subscriber. Subscriber arrival order is exactly fold order - no
buffering, no batching, nothing to reorder.

**The four seam crossings** ADR-0043 names, all converging on the private
`deliver_internal/6` - and all reached from inside that fold *except* on the
fired-timer path, which Phase 1 change 4 handles separately:

- `perform_instruction({:raise, kind, name, origin, opts}, ...)` -
  `lib/statifier/session.ex:947-949`
- `perform_instruction({:deliver, route, event, effect}, ...)` ->
  `deliver(:internal, ...)` - `lib/statifier/session.ex:953-955`,
  `lib/statifier/session.ex:1200-1209`
- `communication_error/4` (unreachable `<send>` target) -
  `lib/statifier/session.ex:1318-1327`
- `invoke_error/4` (a failed `<invoke>`) - `lib/statifier/session.ex:1165-1174`,
  reached from `{:start_child, ...}` at `lib/statifier/session.ex:997-1002`

`deliver_internal/6` (`lib/statifier/session.ex:1342-1354`) records the call
(`Recording.put_internal/5`), opens its own `in_macrostep(state, :internal,
nil, ...)` span, calls `Statifier.Interpreter.deliver_internal/5`, and calls
`perform/3` on the result. That inner `perform/3` runs to completion -
notifying every re-entry effect - before the outer `Enum.reduce/3` resumes.

**Why the rounds invert.** `Interpreter.deliver_internal/5`
(`lib/statifier/interpreter.ex:490-499`) does not call
`MachineState.begin_macrostep/1`; it raises onto the internal queue and folds
`main_event_loop/1`. The re-entry keeps the enclosing `macrostep` and pushes
`round` forward, so its effects carry *higher* rounds than the outer batch's
unsent tail.

**Why `{:halted, _}` is not last.** `{:halt, reason}` is planned as the second
instruction of a `{:done, _}` effect (`lib/statifier/session/effects.ex:141-147`)
and performed at `lib/statifier/session.ex:1053-1060`. When the run
terminates inside a re-entry, that notify happens inside the nested
`perform/3` and the outer fold keeps notifying afterwards. `state.halted` is
only consulted at `handle_continue(:drain, _)`
(`lib/statifier/session.ex:641-684`), never inside `perform/3`.

**What is already right and must not move.** The recording entry is written
before the span opens (`lib/statifier/session.ex:1343`), and
`Statifier.Replay` walks that flat ordinal list, applying the
`{:internal, ...}` entry *after* the entry that triggered it
(`lib/statifier/replay.ex:72-92`, `lib/statifier/replay.ex:238-240`), with
`{:raise, ...}` and non-self `{:deliver, ...}` as no-ops
(`lib/statifier/replay.ex:375-397`). Replay is therefore already monotone -
it is the live side that diverges, and `round_trip/3`
(`test/statifier/replay_round_trip_test.exs:103-119`) already asserts exact
ordered stream equality (`result.stream == stream`). No existing round-trip
case drives a seam-crossing chart, which is the only reason it is green.

**The counter gap that constrains the tests.** Only the nine `Effect.Trace.*`
payloads and `Effect.BudgetExhausted` carry `round`; every other core effect
carries `macrostep`/`microstep` only (`lib/statifier/effect.ex:52-63`).
`{:halted, _}` and `{:unroutable, _}` are envelopes and carry no counters at
all. ADR-0043 decision 4 leaves that gap open deliberately, so a `(macrostep,
round)` monotonicity assertion can only be evaluated over the counter-bearing
sub-stream (see "Testing Strategy").

**Existing test exposure.** `test/statifier/session/telemetry_test.exs:1276-1327`
is the only place that asserts on the nested `:internal` span; it checks
`trigger`, `span_ref` pairing, and `measurements.macrostep == 1`, and never
asserts that span's `outcome`. The `internal_send_doc/1` cases in
`test/statifier/session_test.exs:655-722` assert configuration and
`_event` fields, never arrival order. `test/statifier/replay_test.exs:370-386`
and `:420-437` do cross the seam but start their sessions without
`subscribers:`.

## Desired End State

`Statifier.Session` delivers `{:effect, _}` messages to every subscriber in
non-decreasing `(macrostep, round)` order - the same order
`Statifier.Replay` produces for the same recording - at any re-entry nesting
depth, and `{:halted, reason}` is the last message a session sends for the
run. The core's `%MachineState{}` still advances at the seam's true
instruction position, the ADR-0034 recording entry is still written there,
and the ADR-0040 span still opens and closes around the core drive.

Verified by:

- `mix quality` green.
- A regression test on the invoke-failure path (the bead's acceptance
  criterion) asserting non-decreasing `(macrostep, round)` arrival with
  exactly one `Trace.MacrostepStable` per `(macrostep, round)`.
- A regression test on the internal-send success path (the bead's 2026-08-16
  note) asserting the same plus `{:halted, :done}` last.
- A seam-crossing case in `test/statifier/replay_round_trip_test.exs` whose
  `result.stream == stream` assertion holds, closing the live-vs-replay
  divergence from both sides.
- `docs/observability.md` constraints 2, 4, and 6 and the
  `Statifier.Session` moduledoc stating the two promises.

### Key Discoveries:

- `perform/3`'s only nested call site is `deliver_internal/6`
  (`lib/statifier/session.ex:1348`); the other three are top-level drives
  (`handle_continue({:initialize, ...}, _)` at `:617-631`,
  `handle_cast({:interpret, effects}, _)` at `:739-743`, `drain_cancel/1` /
  `drain_event/2` at `:830-857`). Removing that one nested call makes
  *every* remaining `perform/3` call outermost by construction - no depth
  counter, no "am I the outer one" flag.
- **But `deliver_internal/6` itself has a caller outside every `perform/3`**:
  `deliver_fired/4` (`lib/statifier/session.ex:1285-1289`), on the
  fired-timer path from `handle_info({:statifier_delayed_send, ...}, state)`.
  A deferral with no drain there strands the effects. Phase 1 change 4 is
  that drain, and it is the single most likely thing to be missed while
  implementing this - the four crossings ADR-0043 enumerates are all
  in-fold, so the enumeration does not lead you to it.
- FIFO is monotone with no sorting, at any depth: each seam crossing's core
  drive happens at its instruction position, so rounds are stamped in the
  same order batches are appended to the queue, and a deferred batch that
  crosses the seam again appends to the back after both.
- The halt cannot escape the last batch: a drive that reaches a terminal
  configuration leaves the core not running, so a later seam crossing gets
  `{:error, :not_running}` from `Interpreter.deliver_internal/5`
  (`lib/statifier/session.ex:1350`) and enqueues nothing. That is ADR-0043
  decision 2's argument, and the regression suite asserts it rather than
  trusting it. It holds *within* the halting batch too:
  `terminal_effects/2` emits `Trace.MacrostepStable` only when the machine
  is still `running` (`lib/statifier/interpreter.ex:1005-1013`), so a
  terminating drive appends no trace effect after the `{:done, _}` that
  `exit_interpreter/1` produced, and `plan_one({:done, _}, _)` puts
  `{:halt, :done}` immediately after that effect's own notify
  (`lib/statifier/session/effects.ex:141-143`). Nothing in the batch follows
  the halt.
- The drain runs *inside* the outermost drive's `in_macrostep/4` span
  (`lib/statifier/session.ex:874-903`), because `drain_event/2` and
  `drain_cancel/1` call `perform/3` from inside the closure. So the outer
  span's `outcome` still reports the halt; only the nested `:internal`
  span's `outcome` changes (see Phase 1's decision on it).
- `Statifier.Case` (`test/support/case.ex`) is the corpus harness and is
  constrained by ADR-0006 to the four-function contract; the ordering
  helpers belong in a new support module, not there.
- **`Statifier.Replay` needs no mirroring change, and mirroring it would be a
  regression.** `Replay.perform_internal/5` (`lib/statifier/replay.ex:332-340`)
  does call `perform/3` inline, which looks like the same shape - but every
  re-entering instruction inside that batch is already a no-op deferring to
  the *next recorded* `{:internal, ...}` entry
  (`lib/statifier/replay.ex:375-397`), so replay never nests and its stream is
  already flat. Adding a deferral queue there would double-defer. The
  divergence in shape between the two modules is the ADR-0034 design, not an
  oversight.
- **The recording's entry order shifts only for a two-level re-entry, and
  replay follows it.** `record(state, &Recording.put_internal/5)` still runs
  at the crossing's instruction position (`lib/statifier/session.ex:1343`), so
  a single level records identically. A crossing that happens *inside* a
  deferred batch is now recorded during the drain rather than mid-nest, which
  is exactly the order live delivery uses - and replay walks the recording, so
  the two stay equal.
- No Appendix D function moves. The deviation is session-side sequencing on
  the effect-interpreter side of ADR-0003's boundary, so no new ADR-0002
  mechanical-reason comment is owed in `lib/statifier/interpreter.ex` -
  ADR-0043's "Documentation edits this record directs" says this outright.

## What We're NOT Doing

- **Stamping `round` onto core effects.** ADR-0043 decision 4 rules it out of
  scope and files it as follow-on work; it reopens ADR-0040's struct-shape
  contract when taken. The tests here therefore evaluate `(macrostep,
  round)` over the counter-bearing sub-stream and `macrostep` alone over the
  rest, which is exactly what the shipped contract can promise today.
- **Giving the `:internal` macrostep span a non-`nil` `event`**
  (`lib/statifier/session.ex:1345`). Research open question 4; ADR-0043
  consequences file it separately. Deferral neither worsens nor fixes it.
- **The stale "not yet produced" vocabulary note** at
  `lib/statifier/effect.ex:26-28`. Research open question 6, filed as a chore.
- **Suppressing the intermediate `Trace.MacrostepStable`.** ADR-0043
  decision 3 rejects it: it would hide a boundary the core genuinely crossed
  and would diverge from replay, which re-derives it.
- **Sorting anywhere.** Decision 1 is a queue, not a sort. No buffering
  keyed on counters, no watermark.
- **Amending ADR-0040.** The telemetry ordering shift is a noted consequence
  of ADR-0043, not an amendment; ADR-0040 promised no inter-event ordering.
- **A `changelog.d/st-r6l9.md` fragment.** Judged against
  `changelog.d/README.md`'s "While v2 is unreleased" rule: a fragment is owed
  when v2 differs from v1. The subscriber effect stream is a v2-only
  capability with no v1 counterpart, already announced by
  `changelog.d/st-cmq.4.md`'s `Added` entry, and nothing here is released -
  so an upgrading 1.x user cannot tell the difference. If a reviewer
  disagrees, the fix is one `### Changed` line saying subscribers receive
  effects in non-decreasing `(macrostep, round)` order with `{:halted, _}`
  last; it does not change any phase.
- **Changing `Statifier.Replay`.** It is already monotone by construction
  (`lib/statifier/replay.ex:72-92`); this plan moves the live side to match
  it. A reading of `Replay.perform_internal/5`'s inline `perform/3` call as
  "the same bug over there" was raised during planning and rejected: the
  instructions that would re-enter are already no-ops there, so replay never
  nests, and adding a deferral queue would defer an already-deferred batch.
  See Key Discoveries.

## Implementation Approach

Three phases, each independently committable behind a full `mix quality`.

Phase 1 is the mechanism plus its two live-subscriber regression tests plus
the promises the module itself makes. These cannot be split: a test asserting
monotone arrival is red without the deferral, and a deferral with no test is
a phase whose gate proves nothing about the property it exists for. The
moduledoc rides along because a commit that changes the delivery contract and
leaves `lib/statifier/session.ex:74-76` still promising only "following the
effects that caused it" ships a file that contradicts itself.

Phase 2 adds the cross-check from the other side: a seam-crossing chart in
the replay round-trip suite, where `round_trip/3`'s existing `result.stream
== stream` assertion becomes a standing guard on the property. It must
follow Phase 1 - it is red before it.

Phase 3 is `docs/observability.md`, the project-level constraints document,
edited last so no commit documents a promise the shipped code does not yet
keep.

The mechanism itself:

```elixir
# perform/3 becomes a two-step: reduce this batch, then drain whatever the
# batch's seam crossings enqueued.
defp perform(state, effects, opts \\ []) do
  state
  |> perform_batch(effects, Keyword.get(opts, :halt_override))
  |> drain_deferred()
end
```

with `deliver_internal/6`'s `perform/3` call replaced by an append onto
`state.deferred`. Because that was `perform/3`'s only nested call site, every
surviving call is outermost and `drain_deferred/1` never nests.

## Phase 1: Defer re-entry effects to the outer batch

### Overview

Replace `deliver_internal/6`'s inline recursive `perform/3` with a FIFO
deferral queue on `%State{}`, drained by the outermost `perform/3`. State the
two strengthened promises in the `Statifier.Session` moduledoc. Land the two
live-subscriber regression tests and the shared assertion helper they need.

### Changes Required:

#### 1. The deferral queue field

**File**: `lib/statifier/session.ex` (the `State` submodule, `:274-317`)
**Changes**: add `deferred: []` to `defstruct` and to `@type t`, with a
comment saying what it holds and when it is guaranteed empty.

```elixir
defstruct [
  # ... unchanged ...
  macrostep_started_at: nil,
  deferred: []
]

# ADR-0043 decision 1: effects returned by a mid-batch ADR-0039 seam
# crossing, queued in crossing order with the `halt_override` that was in
# force when they were produced, and drained FIFO by the outermost
# `perform/3` once its own instruction list is exhausted. Always `[]`
# outside a `perform/3` call - every callback that reads `%State{}` sees an
# empty queue.
deferred: [{[Statifier.Effect.t()], :cancelled | nil}]
```

#### 2. `perform/3` splits, and gains the drain

**File**: `lib/statifier/session.ex:912-919`
**Changes**: `perform/3` reduces its own batch and then drains; the reduce
moves into `perform_batch/3` so that the drain loop does not re-enter itself.

```elixir
# ADR-0043 decision 1. `perform_batch/3` is the old body; the drain after it
# is what makes subscriber arrival order non-decreasing in `(macrostep,
# round)`. `deliver_internal/6` no longer calls this function at all, so
# every call site is an outermost drive and `drain_deferred/1` never nests.
@spec perform(state :: State.t(), effects :: [Effect.t()], opts :: keyword()) :: State.t()
defp perform(state, effects, opts \\ []) do
  state
  |> perform_batch(effects, Keyword.get(opts, :halt_override))
  |> drain_deferred()
end

@spec perform_batch(
        state :: State.t(),
        effects :: [Effect.t()],
        halt_override :: :cancelled | nil
      ) :: State.t()
defp perform_batch(state, effects, halt_override) do
  effects
  |> Effects.plan(state.session_id)
  |> Enum.reduce(state, &perform_instruction(&1, &2, halt_override))
end

# FIFO, and monotone with no sorting at any nesting depth: each crossing's
# core drive already happened at its instruction's position, so rounds were
# stamped in the same order batches were appended, and a deferred batch that
# crosses the seam again appends behind every batch already queued.
@spec drain_deferred(state :: State.t()) :: State.t()
defp drain_deferred(%State{deferred: []} = state), do: state

defp drain_deferred(%State{deferred: [{effects, override} | rest]} = state) do
  %{state | deferred: rest}
  |> perform_batch(effects, override)
  |> drain_deferred()
end
```

#### 3. `deliver_internal/6` enqueues instead of performing

**File**: `lib/statifier/session.ex:1329-1354`
**Changes**: the `{:ok, machine_state, effects}` arm appends to
`state.deferred` rather than calling `perform/3`. The record call, the
`in_macrostep/4` span, and the `{:error, :not_running}` no-op are unchanged.
Rewrite the leading comment to cite ADR-0043 where the inline `perform/3`
call used to be (ADR-0043's directed edit).

```elixir
# The one call site of `Interpreter.deliver_internal/5` - records the call
# (ADR-0029, `docs/observability.md` constraint 6) before making it, then
# **queues** whatever effects it returns instead of performing them here.
# ADR-0043 decision 1: the seam is still crossed at this instruction's
# position - the core's `%MachineState{}` advances now, the recording entry
# is written at its true position, and this nested ADR-0040 span still opens
# and closes around the core drive - but notifying the returned effects
# inline is what put them ahead of the tail of the batch that triggered
# them. The outermost `perform/3` drains the queue instead.
#
# One consequence to read deliberately: this nested span's `outcome`
# (`macrostep_outcome/1`, reading `state.halted`) is now always
# `:quiescent`, because a halt inside the deferred batch is performed later,
# during the drain. That drain runs inside the *outermost* drive's span, so
# the run's halt outcome is still reported - once, on the span that
# encloses the batch that actually performed `{:halt, _}`. ADR-0043's
# consequences record the same shift for effect-vs-span event ordering.
# `{:error, :not_running}` is a no-op: a halted session has no queue to
# raise onto, and nothing is queued.
defp deliver_internal(kind, name, origin, opts, state, override) do
  state = record(state, &Recording.put_internal(&1, kind, name, origin, opts))

  in_macrostep(state, :internal, nil, fn state ->
    case Interpreter.deliver_internal(state.machine_state, kind, name, origin, opts) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state, deferred: state.deferred ++ [{effects, override}]}

      {:error, :not_running} ->
        state
    end
  end)
end
```

`++` on the tail is deliberate: the queue holds one entry per seam crossing
in a single batch, which is a handful at most, and a reversed accumulator
would trade readability for nothing measurable.

#### 4. The one seam crossing that is *not* inside a `perform/3`

**File**: `lib/statifier/session.ex:756-769` (`handle_info({:statifier_delayed_send,
...}, state)`)
**Changes**: this is the case that makes an unguarded deferral wrong, and it
must land in the same commit as change 3.

Enumerate every caller of `deliver_internal/6`:

- `perform_instruction({:raise, ...}, ...)` - inside `perform/3`
- `perform_instruction({:deliver, route, ...}, ...)` -> `deliver/5` - inside
- `perform_instruction({:start_child, ...}, ...)` -> `invoke_error/4`, and
  `start_child/5`'s own failure arm -> `invoke_error/4` - inside
- `deliver_fired/4` (`lib/statifier/session.ex:1285-1289`) -> `deliver/5`
  -> `deliver(:internal, ...)` **or** `communication_error/4` - **not
  inside any `perform/3`**

That last one is reached from `handle_info({:statifier_delayed_send, ...},
state)`, the fired-timer path, when a `<send delay="...">` targets
`#_internal` or resolves to a route that has since become unreachable. Today
it performs inline and the effects are delivered. Under an unguarded
deferral they would be enqueued onto `state.deferred` and stranded there -
never drained, or drained at some unrelated later `perform/3` call, which is
worse than the bug being fixed. Drain it explicitly:

```elixir
state = deliver_fired(route, event, effect, state) |> drain_deferred()
```

Add a comment at that call site saying why the drain is there, and note that
`drain_deferred/1` on an empty queue is a single pattern match, so the
non-seam-crossing routes (`:self`, a live `{:session, sid}`, `:parent`,
`{:invoke, _}`) pay nothing.

**Its own telemetry consequence, which differs from change 3's.**
`handle_info({:statifier_delayed_send, ...}, state)` never opens an
`in_macrostep/4` span of its own - only the nested `:internal` one that
`deliver_internal/6` opens. Today that nested span encloses the re-entry's
notifications, because the inline `perform/3` runs inside it. After this
change the drain happens at the `handle_info` level, so on *this* path the
deferred batch's `{:effect, _}` notifications and `[:statifier, :session,
:effect]` telemetry events arrive with **no enclosing macrostep span at
all** - not merely after the span closes, as on the in-fold paths. Say so in
the call-site comment. Accept it rather than manufacturing an outer span
here: ADR-0040's span vocabulary has no trigger for "a timer fired", the
`:internal` span already covers the core drive that produced the effects,
and inventing one would be an ADR-0040 change this bead is not authorized to
make. If a telemetry consumer turns out to need it, that is a new bead
against ADR-0040, not a quiet addition here.

The invariant this establishes, and which the manual criteria below check by
reading the callers rather than by trusting this list: **`state.deferred` is
empty whenever control returns to the GenServer loop.** Any future caller of
`deliver_internal/6` added outside a `perform/3` owes a drain the same way.

#### 5. The `in_macrostep/4` nesting comment

**File**: `lib/statifier/session.ex:859-884`
**Changes**: the comment still describes `drive.()` calling
`deliver_internal/6` and nesting a span, which stays true. Add one sentence
noting that the nested span no longer encloses the *performance* of the
effects the crossing produced (ADR-0043), so its duration now measures the
core drive alone.

#### 6. The moduledoc's two promises

**File**: `lib/statifier/session.ex:59-77` ("One subscriber stream")
**Changes**: the `{:effect, effect}` bullet gains the ordering promise; the
`{:halted, ...}` bullet is strengthened to end-of-stream.

```
  - `{:effect, effect}` - every effect the core (or an `interpret/2`
    caller) hands this session, trace effects included, in
    non-decreasing `(macrostep, round)` order - the same order
    `Statifier.Replay` produces for the same recording (ADR-0043
    decision 1). An ADR-0039 re-entry crosses the seam at its own
    instruction's position but its effects are queued and drained after
    the batch that triggered it, so a subscriber never sees a later
    round ahead of an earlier one. Trace effects are ordinary list
    members here too, never a side channel. A macrostep may carry more
    than one `Trace.MacrostepStable` - one per core drive that reached
    quiescence - and there is exactly one per `(macrostep, round)`; the
    last one within a macrostep is that macrostep's true quiescence
    (ADR-0043 decision 3).
  - `{:halted, :done | :cancelled | :budget_exhausted}` - one lifecycle
    message, following the effects that caused it, and the **last**
    message this session sends its subscribers for the run (ADR-0043
    decision 2).
```

#### 7. Shared ordering assertions for tests

**File**: `test/support/stream_order.ex` (new)
**Changes**: a small `Statifier.StreamOrder` module the regression tests
share. It is harness plumbing, so it carries `# sabotage: n/a - test
plumbing, no lib/ behavior of its own` per `docs/testing.md`.

```elixir
defmodule Statifier.StreamOrder do
  @moduledoc """
  Assertions over a drained `Statifier.Session` subscriber stream, for the
  ADR-0043 delivery-order contract.

  `round` lives only on the `Effect.Trace.*` payloads and on
  `Effect.BudgetExhausted` today (ADR-0043 decision 4 leaves stamping it
  onto the rest as follow-on work), so `assert_monotone/1` evaluates
  `(macrostep, round)` over exactly the effects that carry both, and
  `macrostep` alone over the effects that carry only it. That is the whole
  contract the shipped structs can express.
  """

  # drain/1  - receive every {:statifier, session_id, message}, envelope
  #            stripped, until a quiet window; preserves arrival order.
  # assert_monotone/1        - (macrostep, round) non-decreasing over the
  #                            counter-bearing sub-stream, and macrostep
  #                            non-decreasing over every counter-bearing
  #                            effect. Flunks naming the first inversion and
  #                            its two neighbours.
  # assert_stable_unique/1   - exactly one Trace.MacrostepStable per
  #                            (macrostep, round).
  # assert_halted_last/1     - a {:halted, _} message, if present, is the
  #                            final element.
end
```

`drain/1` is modelled on `drain_stream/2`
(`test/statifier/replay_round_trip_test.exs:91-97`); that file's own private
copy stays where it is, since `round_trip/3` already uses it and churning it
buys nothing.

#### 8. Regression test: the invoke-failure path

**File**: `test/statifier/session/invoke_start_child_test.exs`
**Changes**: a test in the existing `describe "a runtime that cannot start
the child"` block, which already terminates `Statifier.SessionSupervisor`
for the span of a test and restores it in `after`
(`:190-205`). Start the parent with `trace: true, subscribers: [self()]`,
wait for the `"failed"` configuration, drain, and assert
`assert_monotone/1` and `assert_stable_unique/1`. This is the bead's
acceptance criterion verbatim.

```
# sabotage: `deliver_internal/6`'s `deferred: state.deferred ++ [{effects,
# override}]` is changed back to `|> perform(effects, halt_override:
# override)` -> the invoke re-entry's `Trace.InvokePass`/
# `Trace.MacrostepStable` at round 3 arrive before the outer batch's round 1
# pair, reddening `assert_monotone/1`.
```

#### 9. Regression test: the internal-send success path

**File**: `test/statifier/session_test.exs`, alongside the existing
`internal_send_doc/1` block (`:655-722`)
**Changes**: the bead's 2026-08-16 chart - `a -go-> b`, `b`'s `<onentry>`
does `<send event="ping" target="#_internal"/>`, `b -ping-> c` where `c` is
a top-level `<final>` - started with `trace: true, subscribers: [self()]`.
Send `"go"`, wait for `:done`, drain, and assert all three: monotone,
one stable per `(macrostep, round)`, and `{:halted, :done}` last. The third
assertion is the one that covers ADR-0043 decision 2 and the "silently
drops the tail" consequence the bead reports.

Use the existing `internal_send_doc/1` shape as the model for the XML;
per repo convention it is a triple-quoted heredoc at 4-space base
indentation. Keep it as its own document helper rather than widening
`internal_send_doc/1`, whose three existing callers assert on `_event`
fields and should not change.

```
# sabotage: same mutation as the invoke-failure test -> the outer batch's
# `Trace.ContentExecuted` (m=2 r=0) and the round-1 `TransitionsSelected`/
# `InvokePass`/`MacrostepStable` trio arrive after `{:halted, :done}`,
# reddening both `assert_monotone/1` and `assert_halted_last/1`.
```

#### 10. Regression test: the fired-timer seam crossing

**File**: `test/statifier/session_test.exs`, in the delayed-send describe
block that already holds `delayed_self_targetexpr_doc/0` (`:920-961`)
**Changes**: a chart with `<send event="e" delay="10ms" target="#_internal"/>`
in `<onentry>` and a transition on `"e"`. Started with `trace: true,
subscribers: [self()]`, driven to its target configuration, drained, and
asserted monotone. This is the change-4 path: without the explicit
`drain_deferred/1` on the fired-timer branch, the internal event's effects
are never delivered to a subscriber at all, so this test also pins the
invariant that `state.deferred` is empty when control returns to the
GenServer loop.

```
# sabotage: `handle_info({:statifier_delayed_send, ...}, state)`'s
# `|> drain_deferred()` is removed -> the fired `#_internal` delivery's
# effects sit in `state.deferred` forever, the subscriber never receives the
# transition's trace effects, and the drain assertion times out.
```

Note for the implementer: the chart still reaches its target configuration
without the drain, because the *core* advanced at the seam. Only the
subscriber stream is missing the effects. Assert on the drained stream, not
on `wait_for_status/2` alone, or this test cannot fail.

#### 11. Nesting depth, checked rather than assumed

**File**: whichever of the two test files above the chart fits (prefer
`test/statifier/session_test.exs`)
**Changes**: ADR-0043's open questions ask whether a re-entry whose own
deferred batch crosses the seam again is reachable from a document. Attempt
it with a chart whose `#_internal` send lands in a state whose `<onentry>`
issues a second `#_internal` send, and assert the same three properties. If
the chart provably cannot produce a second crossing from inside a deferred
batch, record that in a comment on the test - the FIFO argument covers both
outcomes, and what this phase owes is the attempt and its recorded result,
not a guaranteed second level.

```
# sabotage: `drain_deferred/1`'s recursive clause drops its trailing
# `|> drain_deferred()` so the drain performs only the first queued batch ->
# the second-level re-entry's effects are never delivered and the drained
# stream is missing its highest-round trace effects. (If the chart turns out
# to reach only one level, sabotage instead with the shared mutation - revert
# `deliver_internal/6` to the inline `perform/3` call - and say so in the
# comment.)
```

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (use `mix quality --profile loop` between
      edits; a loop run alone never satisfies this phase).
- [x] `mix gate.verify` confirms the green run was a full, unscoped,
      un-`--skip`-ed gate.
- [x] The new regression tests pass - invoke-failure (change 8),
      internal-send success (change 9), fired-timer crossing (change 10),
      nesting-depth attempt (change 11) - and each was confirmed red under
      the sabotage mutation named in its comment before being reverted.
- [x] `test/statifier/session/telemetry_test.exs` stays green **unmodified**.
      A sweep of it before planning found: the only two `trigger: :internal`
      tests (`:1229` and `:1302`) assert `measurements.macrostep`,
      `:macrostep` key-absence on start, and `span_ref` pairing/nesting -
      never that span's `outcome`; the two `outcome` assertions (`:344`,
      `:1117`) are a direct unit call and an `:initialize`-trigger span
      respectively; and the one test coupling effect events to span events
      (`:1017`) drives a two-state chart that never crosses the seam. So the
      documented `outcome` and event-ordering shifts are unobserved by it.
      If it does redden, the failure is a real finding about ADR-0040
      metadata and belongs on the bead - never a test edit made to go green.
- [x] Every existing seam-crossing test stays green unmodified. They all poll
      `Session.status/1` for a configuration rather than asserting a message
      sequence: `test/statifier/session_test.exs:654-722`, `:881`, `:914`,
      `:952`, `:971`; `test/statifier/session/send_cancel_test.exs:207`;
      `test/statifier/session/invoke_start_child_test.exs:190,220,235,250`;
      `test/statifier/session/invoke_send_target_test.exs:107,135`;
      `test/statifier/session/invoke_parent_routing_test.exs:142`;
      `test/statifier/session_runtime_test.exs:126,148`;
      `test/statifier/replay_test.exs:370,420`. That they are all
      order-insensitive is why this bug survived to be reported by a
      downstream consumer rather than by the suite.
- [x] `mix test --include scion --include scxml_w3` shows no newly failing
      conformance test, and `mix test.regression` is green (the ratchet is
      not expected to move - delivery order is not something the corpus
      harness observes, since `Statifier.Case` polls status rather than
      reading mailbox order - so a change here would itself be the finding).
      **`mix test.baseline add` is deliberately not part of this phase.**
      `.claude/wurk/plan.md` pairs it with `mix test.regression` for phases
      that can move conformance results; this one is not expected to move any,
      so if the ratchet does shift, that is a blocking finding to report on
      the bead - not something to absorb by re-baselining. Re-baselining here
      would be going green by weakening the check.

#### Manual Verification:

- [ ] Spec-conformance judgment: no Appendix D function moved. The change is
      entirely on the effect-interpreter side of ADR-0003's boundary, so
      `lib/statifier/interpreter.ex` is untouched and no new ADR-0002
      mechanical-reason comment is owed - confirm by diff.
- [ ] The `%State{}` `deferred` queue is empty at every GenServer callback
      boundary. Check it by re-walking the callers of `deliver_internal/6`
      in the finished diff, not by trusting the plan's list: every one must
      be either inside a `perform/3` or followed by an explicit
      `drain_deferred/1` (today that exception is `deliver_fired/4` on the
      fired-timer path, change 4). This is the invariant the whole design
      rests on and the one a future caller can silently break.
- [ ] The fired-timer path's telemetry shape is confirmed and accepted, not
      discovered later: attach a handler to `[:statifier, :session,
      macrostep, :start | :stop]` and `[:statifier, :session, :effect]`, fire
      a delayed `#_internal` send, and confirm the deferred batch's effect
      events land outside every macrostep span. `telemetry_test.exs` has no
      fired-timer `:internal` coverage today, so nothing else will surface
      this either way - which is why it is a manual check rather than an
      automated one, and why change 4's comment has to state it.
- [ ] The strengthened moduledoc reads as a promise a consumer can act on,
      and matches ADR-0043 decisions 1, 2, and 3 rather than paraphrasing
      them loosely.
- [ ] No regressions in related features: internal sends, `<raise>`-driven
      `error.execution`, unreachable `<send>` targets, and `<invoke>`
      failures all still reach the same configurations.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: A seam-crossing replay round-trip

### Overview

`round_trip/3` already asserts exact ordered stream equality between a
drained live subscriber and `Statifier.Replay`'s reconstructed stream. Point
it at a chart that crosses the ADR-0039 seam, so the live-vs-replay property
guards ADR-0043 decision 1 mechanically from the other side.

### Changes Required:

#### 1. A seam-crossing case

**File**: `test/statifier/replay_round_trip_test.exs`
**Changes**: a new `describe` block with a document whose `<onentry>` issues
`<send event="ping" target="#_internal"/>` and whose run reaches a top-level
`<final>` - the same shape as Phase 1's success-path chart, so the two tests
fail for the same reason if the deferral regresses. Drive it through
`round_trip/3` unchanged; the assertion that matters (`result.stream ==
stream`) is already inside it. Add case-specific assertions on the returned
triple: the recording carries the `{:internal, ...}` entry, and the drained
stream's last message is `{:halted, :done}`.

```
# sabotage: `deliver_internal/6`'s deferral is reverted to the inline
# `perform/3` call -> the live stream interleaves the re-entry ahead of the
# outer batch's tail while replay keeps the recording's flat order, so
# `round_trip/3`'s `result.stream == stream` fails on order alone - same
# multiset, same terminal `%MachineState{}`.
```

#### 2. A second crossing kind

**File**: `test/statifier/replay_round_trip_test.exs`
**Changes**: a second case over a failing route - a `<send>` to an
unreachable `#_scxml_<id>` target, which reaches the seam through
`communication_error/4` rather than `deliver(:internal, ...)`. This is the
`error.communication` half of the four crossings and confirms the property
does not depend on which door was used.
`test/statifier/replay_test.exs:370-386` already drives this shape without a
subscriber and is the model for the document.

### Success Criteria:

#### Automated Verification:

- [ ] Full `mix quality` passes (`mix quality --profile loop` while
      iterating).
- [ ] Both new round-trip cases pass, and both were confirmed red under the
      sabotage mutation before it was reverted.
- [ ] `mix gate.verify` confirms the run was a full gate.

#### Manual Verification:

- [ ] Spec-conformance judgment: this phase touches only `test/`, so no
      Appendix D function is in scope; confirm by diff that
      `lib/statifier/` is untouched.
- [ ] The two charts genuinely cross the seam - confirm by observing the
      `{:internal, ...}` entry in the recording each produces, not by
      assuming the document shape is enough.
- [ ] Replay's stream and the live stream match for a reason, not by
      coincidence: spot-check that both contain more than one
      `Trace.MacrostepStable` for the terminal macrostep.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: The observability constraints

### Overview

ADR-0043 directs three edits to `docs/observability.md`. They land last, so
no commit on this branch documents a promise the shipped code does not keep.
This phase touches no Elixir code.

### Changes Required:

#### 1. Constraint 2 gains the cross-batch sentence

**File**: `docs/observability.md:86-87`
**Changes**: the existing bullet ("Trace effects are ordinary members of the
effect list - same ordering guarantees, same delivery path. No side
channel.") is true but silent about the relationship between two *different*
lists, which is exactly what a re-entry creates. Add the cross-batch half:
delivery order to a subscriber is non-decreasing in `(macrostep, round)`
across batches too, matching the order `Statifier.Replay` produces for the
same recording, because a mid-batch ADR-0039 re-entry's effects are queued
and drained after the batch that triggered them (ADR-0043 decision 1).

#### 2. Constraint 4 gains the `MacrostepStable` uniqueness key

**File**: `docs/observability.md:117-133`
**Changes**: the "ordering key for any timeline UI or log merge" bullet keeps
its wording; add that a macrostep may contain more than one
`Trace.MacrostepStable` - one per core drive that reached quiescence, since
a session may re-enter the core mid-macrostep - with exactly one per
`(macrostep, round)`, and that under ADR-0043 decision 1 the last one within
a macrostep is that macrostep's true quiescence. Name ADR-0043 decision 3.

#### 3. Constraint 6 gains the end-of-stream promise

**File**: `docs/observability.md:145-153`
**Changes**: the "Observation" bullet names the `{:statifier, session_id,
{:effect, effect}}` shape and makes no ordering claim. Add that
`{:halted, :done | :cancelled | :budget_exhausted}` is the last message a
session sends its subscribers for the run, so a consumer may treat it as
end-of-stream (ADR-0043 decision 2), and cross-reference constraint 2's
ordering sentence.

### Success Criteria:

#### Automated Verification:

- [ ] Full `mix quality` passes. This phase touches no Elixir code, so per
      `CLAUDE.md` it may commit on review of the diff alone if the gate has
      nothing to run - but run it anyway, since the branch has Elixir
      changes from Phases 1 and 2 in the tree.
- [ ] `git diff --stat` on this phase shows only `docs/observability.md`.

#### Manual Verification:

- [ ] Each of the three edits says what ADR-0043 directs and cites the
      decision number, without re-arguing the decision.
- [ ] The prose matches the surrounding house style of
      `docs/observability.md` (it uses plain hyphens, not em dashes -
      match what is there).
- [ ] Constraints 2, 4, and 6 do not contradict each other or the
      `Statifier.Session` moduledoc written in Phase 1.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- **What can actually be asserted.** `round` lives on the nine
  `Effect.Trace.*` payloads and on `Effect.BudgetExhausted`
  (`lib/statifier/effect.ex:52-63`); every other core effect carries
  `macrostep`/`microstep` only, and `{:halted, _}`/`{:unroutable, _}` carry
  nothing. ADR-0043 decision 4 keeps that gap out of scope, so
  `assert_monotone/1` evaluates `(macrostep, round)` over the effects that
  carry both and `macrostep` alone over the rest. Stating this in the helper's
  moduledoc is what stops the next reader from thinking the assertion is
  weaker than intended.
- **Live subscriber ordering** (Phase 1): the invoke-failure path in
  `test/statifier/session/invoke_start_child_test.exs` (the bead's
  acceptance criterion) and the internal-send success path in
  `test/statifier/session_test.exs` (the bead's 2026-08-16 note). Both drain
  the whole stream and assert monotone arrival plus one
  `Trace.MacrostepStable` per `(macrostep, round)`; the success-path test
  additionally asserts `{:halted, :done}` last.
- **Nesting depth** (Phase 1): the attempted two-level re-entry chart, with
  its outcome recorded in a comment either way - ADR-0043 carries this as an
  open question and asks the regression suite to try to construct one.
- **Live-vs-replay equality** (Phase 2): two seam-crossing charts through
  `round_trip/3`, one via `deliver(:internal, ...)` and one via
  `communication_error/4`.
- **Sabotage** (`CLAUDE.md`, `docs/testing.md`): every new test asserting
  `lib/` behavior names its mutation in a one-line comment above itself, and
  the mutation for all of them is the same one - revert `deliver_internal/6`
  to the inline `perform/3` call. `test/support/stream_order.ex` is harness
  plumbing and states `# sabotage: n/a - ...` rather than omitting the line.
- **Edge cases each test must not skip**: a session with no subscribers (the
  drain must not change behavior); a seam crossing on an already-halted
  machine (`{:error, :not_running}` enqueues nothing); a `cancel/1` run whose
  deferred batch carries `halt_override: :cancelled` through to
  `{:halt, reason}`.

### Manual Testing Steps:

1. Start a `trace: true` session on the bead's success-path chart with
   `subscribers: [self()]`, drive it to `:done`, and read the drained
   mailbox in order: confirm the arrival sequence is the one ADR-0043
   describes, with the outer batch's `Trace.ContentExecuted` (m=2 r=0) and
   round-1 trio ahead of the re-entry's round-2/3 effects, and
   `{:halted, :done}` last - the exact inverse of the capture in the bead's
   2026-08-16 note.
2. Attach a `:telemetry` handler to `[:statifier, :session, :macrostep,
   :start | :stop]` and `[:statifier, :session, :effect]` on the same run,
   and confirm the documented consequence: the nested `:internal` span's
   `:stop` now precedes its own batch's effect events, and its `outcome` is
   `:quiescent`. Confirm this is a shift ADR-0043 named, not a surprise.
3. Repeat step 1 on the invoke-failure chart with
   `Statifier.SessionSupervisor` terminated, and confirm the round-1
   `Trace.InvokePass`/`Trace.MacrostepStable` pair no longer arrives after
   the round-3 pair.
4. Read `docs/observability.md` constraints 2, 4, 6 and the
   `Statifier.Session` moduledoc end to end as a consumer would, and confirm
   a timeline UI could be written against them without inferring anything.

## References

- Source document: `docs/research/260817-st-r6l9-invoke-effect-order-reentry.md`
- Decision this plan implements: `docs/adr/0043-re-entry-effects-defer-to-the-outer-batch.md`
- Related ADRs: `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`
  (the seam), `docs/adr/0040-session-telemetry-event-contract.md` (nested
  spans, struct-shape contract), `docs/adr/0034-*` (flat ordinal recording,
  replay drives the core), `docs/adr/0029-*` (recordable
  `deliver_internal/5`), `docs/adr/0020-*` (the counters),
  `docs/adr/0032-*` (one terminal effect per drive), `docs/adr/0003-*`
  (pure core, effects out), `docs/adr/0002-*` (literal Appendix D port),
  `docs/adr/0006-*` (the corpus harness's four-function contract)
- The mechanism: `lib/statifier/session.ex:912-919` (`perform/3`),
  `:947-955` (the two re-entering instruction kinds), `:1342-1354`
  (`deliver_internal/6`), `:1382-1386` (`notify/2`), `:1053-1060`
  (`{:halt, reason}`), `:74-76` (the moduledoc promise)
- Replay's side: `lib/statifier/replay.ex:72-92`, `:238-240`, `:375-397`
- Similar implementation to model tests after:
  `test/statifier/replay_round_trip_test.exs:91-119` (`drain_stream/2`,
  `round_trip/3`), `test/statifier/session/invoke_start_child_test.exs:177-205`
  (the SessionSupervisor-down failure path),
  `test/statifier/session_test.exs:655-722` (`internal_send_doc/1`)
- Bead: `st-r6l9` (mirrors `sui-t36.1` in statifier-ui)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec-conformance judgment: no Appendix D function moved. The change is
      entirely on the effect-interpreter side of ADR-0003's boundary, so
      `lib/statifier/interpreter.ex` is untouched and no new ADR-0002
      mechanical-reason comment is owed - confirm by diff.
- [ ] The `%State{}` `deferred` queue is empty at every GenServer callback
      boundary. Check it by re-walking the callers of `deliver_internal/6`
      in the finished diff, not by trusting the plan's list: every one must
      be either inside a `perform/3` or followed by an explicit
      `drain_deferred/1` (today that exception is `deliver_fired/4` on the
      fired-timer path, change 4). This is the invariant the whole design
      rests on and the one a future caller can silently break.
- [ ] The fired-timer path's telemetry shape is confirmed and accepted, not
      discovered later: attach a handler to `[:statifier, :session,
      macrostep, :start | :stop]` and `[:statifier, :session, :effect]`, fire
      a delayed `#_internal` send, and confirm the deferred batch's effect
      events land outside every macrostep span. `telemetry_test.exs` has no
      fired-timer `:internal` coverage today, so nothing else will surface
      this either way - which is why it is a manual check rather than an
      automated one, and why change 4's comment has to state it.
- [ ] The strengthened moduledoc reads as a promise a consumer can act on,
      and matches ADR-0043 decisions 1, 2, and 3 rather than paraphrasing
      them loosely.
- [ ] No regressions in related features: internal sends, `<raise>`-driven
      `error.execution`, unreachable `<send>` targets, and `<invoke>`
      failures all still reach the same configurations.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
