# ADR-0019: A round budget bounds the macrostep fold

Status: accepted (2026-08-12) - amended in part by ADR-0020 (2026-08-13)

**Amendment note.**
[ADR-0020](0020-round-ordinal-joins-the-step-counters.md) narrows one clause
of the Decision below: "it does not belong on the struct" covers the budget
countdown - the fold driver's guard, which stays a fold-local accumulator
exactly as written - but not a round *ordinal*, which ADR-0020 adds to
`%MachineState{}` as a third counter under the counter contract. The two
reasons this record gives (guard, not position; a hand-stepper needs no
budget) reach only the countdown, and st-ux0 showed that without an ordinal
the "read the repeating rounds in the effect list" consequence below does not
hold: during a livelock neither existing counter advances, so every round's
effects are byte-identical. Everything else in this record stands.

## Context

Appendix D's inner `while running and not macrostepDone` loop is unbounded,
and the spec says so on purpose. The REC's notes on the algorithm state:
"A microstep always terminates. A macrostep may not. A macrostep that does
not terminate may be said to consist of an infinitely long sequence of
microsteps. This is currently allowed." The pseudocode can afford that
because it presumes a platform underneath it: `mainEventLoop`'s own prose
says the loop "runs until we enter a top-level final state or an external
entity cancels processing." An interpreter running on its own thread can be
cancelled from outside mid-macrostep.

This core cannot. ADR-0003 made the interpreter a pure function -
`(machine_state, event) -> {machine_state, [effect]}` - and moved the
external queue and the cancel seam outward to the session. Inside
`Statifier.Interpreter.macrostep/1`'s fold there is no external entity: a
macrostep that never reaches quiescence never returns, and the calling
process hangs with no recourse short of killing it. The spec's permission
for non-terminating macrosteps rests on a cancellation mechanism the pure
core structurally lacks.

The concrete trigger (st-sd1, found while planning st-af3.2): a `cond` that
deterministically errors on an eventless transition livelocks the fold.
Each round's eventless probe evaluates the failing cond, enqueues
`error.execution`, and selects nothing; the next round dequeues the error
and selects on it, which never re-evaluates the eventless cond (an
event-matched round short-circuits `%Transition{events: []}` before
reaching it), enabling nothing; the queue is empty again and the cycle
repeats forever. Two properties of this livelock shape the fix:

- **No microstep ever runs.** No exit or entry happens, so under
  `MachineState`'s counter contract the `microstep` counter never advances.
  A bound expressed in microsteps would not catch this loop at all; the
  bound has to count rounds of the fold - calls of `microstep/1`, empty
  rounds included.
- **A cond-specific guard was already rejected.** SCXML permits
  non-terminating macrosteps for ordinary eventless self-loops too, and
  Appendix D contains no dedupe, so inventing one inside `Selection` would
  be a semantic deviation with no mechanical reason (ADR-0002). The bound
  must be engine-level and shape-agnostic.

The forward risk is immediate: st-af3.8 flips `conditional_transitions` and
runs the full SCION/W3C conformance suites unattended. A corpus document
that livelocks would hang that run rather than fail it.

## Decision

`Statifier.Interpreter.macrostep/1`'s fold carries a **round budget**: each
`microstep/1` call within one fold consumes one round, whether or not it
advanced the `microstep` counter. When the budget is spent and the fold has
not reached quiescence, it stops.

**The limit is configuration data on `%MachineState{}`.** A new field
`max_macrostep_rounds :: pos_integer() | :infinity`, default `10_000`, set
by `MachineState.new/2` from the option of the same name - `initialize/2`
already passes opts through uninterpreted, so no entry point changes, and
both seams that fold (`initialize/2` and `handle_event/2`) are covered by
one mechanism. The default is roughly three orders of magnitude above the
largest legitimate corpus macrostep and exhausts in milliseconds when hit.
`:infinity` restores the spec's literal "currently allowed" behavior for a
caller that owns its own interruption (say, a `Task` with a timeout).

**The rounds-spent count is a fold-local accumulator**, threaded through
the private `macrostep/2` (becoming `macrostep/3`) exactly like the effects
accumulator that already rides there. It is the fold driver's guard, not
interpreter position, so it does not belong on the struct: constraint 1
(`docs/observability.md`) reifies the position a stepper resumes from, and
a human driving `microstep/1` by hand in iex needs no budget - they are
the bound.

**On exhaustion, the fold returns the position and appends an effect.**
The machine_state comes back exactly as the last round left it - a
complete, inspectable, resumable livelock position, which is ADR-0012's
payoff here: step the returned value through `microstep/1` one round at a
time and watch the cycle with your own eyes. Appended to the effect list is
a new core effect, `{:budget_exhausted, %Statifier.Effect.BudgetExhausted{}}`,
carrying the configuration, the `macrostep`/`microstep` counters, the
budget that was spent, and the pending internal events
(`MachineState.internal_events/1`'s view). No signature changes anywhere:
`handle_event/2` still returns `{:ok, machine_state, effects}`, and the
caller pattern-matches the effect.

It is a **core effect, not a trace effect** - it must be observable with
`trace: false`, because it is the outcome of the call, not diagnostics
about it. This grows the core vocabulary by one member; `Statifier.Effect`'s
"the six core effects - the ADR-0003 set, no more" typedoc becomes "the
ADR-0003 set plus ADR-0019's `:budget_exhausted`", and the vocabulary table
gains its row. `Trace.MacrostepStable` is **not** emitted - the
configuration did not stabilize - so the three macrostep outcomes
(stable, done, budget-exhausted) stay mutually exclusive per macrostep.

The candidates rejected, and why:

- **A platform error event** (`error.execution` or similar on the internal
  queue). Anything enqueued is processed only by the very loop being
  stopped: enqueue-and-continue does not terminate, and enqueue-and-halt
  strands an event nothing will ever dequeue. The error-events principle
  (`docs/architecture.md` principle 3) governs evaluation failures inside a
  running loop; this is the loop itself failing to finish.
- **A tagged return** (`{:error, :budget_exhausted}` or a new tuple shape).
  It would change the return contract of every loop function and push a new
  variant onto every caller, while the effect channel exists precisely so
  the core can report outcomes and leave policy outside (ADR-0003). What to
  do about a livelocked chart - kill the session, alert, retry with a
  bigger budget - is session policy, and the session is an effect
  interpreter.
- **Setting `running: false` and exiting.** `running: false` means a
  top-level final was entered or the platform cancelled; faking it would
  run `onexit` handlers and emit `Effect.Done` for a machine that did not
  finish - a semantic lie. `running` stays `true`, `status` stays
  `:running`, and `exit_interpreter/1` does not run.

A later `handle_event/2` on the returned machine_state begins a new
macrostep with a fresh budget. A deterministic livelock will exhaust it
again and return again - defined and repeatable, never hanging. Whether to
keep feeding such a session events is the session layer's call (st-cmq).

**The ADR-0002 deviation comment** goes on the private fold - the one
place the loop's continue condition lives - immediately above
`defp macrostep/3` in `lib/statifier/interpreter.ex`, joining the existing
hoisting comment there:

    # ADR-0002 mechanical deviation (ADR-0019). Appendix D's inner loop is
    # unbounded, and the REC allows that ("A macrostep may not [terminate].
    # ... This is currently allowed.") because it presumes an interpreter
    # an "external entity" can cancel mid-macrostep. A pure core (ADR-0003)
    # has no external entity inside a fold - a non-terminating macrostep
    # would hang the calling process with no recourse - so the fold spends
    # one round per `microstep/1` call and stops with a `:budget_exhausted`
    # effect when `max_macrostep_rounds` runs out. The loop's condition and
    # body are otherwise unchanged; `max_macrostep_rounds: :infinity`
    # restores the literal spec behavior for a caller that owns its own
    # interruption.

The deviation is mechanical in exactly ADR-0002's sense: the semantics of
every round the budget permits are unchanged, and the budget replaces the
out-of-band cancellation the pseudocode's platform was assumed to provide.

## Consequences

- A macrostep that cannot reach quiescence terminates with a defined,
  observable outcome - the st-sd1 acceptance criterion - and st-af3.8's
  unattended conformance run fails a livelocking document instead of
  hanging on it.
- The effect vocabulary grows by one core member: `Statifier.Effect`'s
  `@type core`, its moduledoc table, and the table-driven `trace?/1` test
  all update; the future session layer must decide its `:budget_exhausted`
  policy when it lands (st-cmq).
- `MachineState` gains one configuration field alongside `trace`, with the
  same "set once in `new/2`, read-only thereafter" discipline.
- The returned machine_state at exhaustion is a live debugging artifact:
  resume it one `microstep/1` at a time in iex, or run it with
  `trace: true` and read the repeating `TransitionsSelected` /
  `EventDequeued` rounds in the effect list.
- Legitimate charts pay one integer decrement per round; charts within
  three orders of magnitude of any real corpus document never notice the
  default. A caller with a genuinely enormous macrostep raises the option
  or passes `:infinity`.
- The conformance harness may choose a lower budget per test to fail fast;
  that is a harness knob at the `MachineState.new/2` seam, not a semantic
  question, and st-af3.8 decides it.
- The literal-port story stays intact: the deviation is one commented
  guard at one port site, diffable against the pseudocode, with the spec's
  own Termination note quoted beside it.
