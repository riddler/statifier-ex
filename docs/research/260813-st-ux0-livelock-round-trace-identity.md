---
date: 2026-08-13T11:48:35-0600
researcher: Claude
git_commit: 1736cf5e4bea4874a81357967c6633c461f1e185
branch: st-ux0-livelock-round-trace
repository: statifier-ex
beads_issue: st-ux0
topic: "How a livelocked macrostep's rounds could be made distinguishable in the trace: the fold, the counter contract, the structs that stamp counters, and the promises ADR-0012/ADR-0019 already make"
tags: [research, codebase, interpreter, observability, trace]
status: complete
last_updated: 2026-08-13
last_updated_by: Claude
---

# Research: Livelock rounds are indistinguishable in the trace (st-ux0)

**Date**: 2026-08-13T11:48:35-0600
**Git Commit**: 1736cf5e4bea4874a81357967c6633c461f1e185
**Branch**: st-ux0-livelock-round-trace
**Bead**: st-ux0

## Research Question

During a livelocked macrostep neither the `macrostep` nor the `microstep`
counter advances, so every effect a round emits is byte-identical to the same
effect in every other round. A reader cannot order the rounds, cannot tell how
many ran, and cannot diff one against another. What does the code look like
today - the fold, the emission sites, the counter contract, the structs that
stamp counters, the documented promises, and the test surface - such that a
later plan can choose between a round ordinal on `%Event.Cause{}`, a round
index on the effects the fold emits, a `rounds_spent` field on
`%Effect.BudgetExhausted{}`, or another engine-level mechanism?

## Summary

The mechanism that makes rounds anonymous is a single, well-localized fact:
**round count exists only as `rounds_left`, an argument to the private
`macrostep/3` fold**, and nothing that stamps an effect can see it. Every
struct in the effect vocabulary - all seven core effects and all seven trace
effects - and `%Event.Cause{}` too, is stamped from `%MachineState{}`'s
`macrostep`/`microstep` fields and from nothing else. Since a livelock by
definition runs rounds that neither begin a macrostep nor begin a microstep,
every stamp in the fold is the same pair of integers.

Three properties shape the design space a plan will work in:

1. **There is exactly one place a per-round number could be read from by
   everything that stamps.** `MachineState` is the sole input to
   `Effect.trace/3`'s payload constructors ([`lib/statifier/effect.ex:150-160`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L150-L160))
   and to `Cause.new/3`'s two callers ([`lib/statifier/machine_state.ex:355`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L355),
   `:388`). A field on `%MachineState{}` reaches `%Event.Cause{}`, all seven
   trace structs, and `%Effect.BudgetExhausted{}` at once. Nothing else does.
2. **ADR-0019 explicitly decided the round count does *not* go on the
   struct**, with a reason that a plan must engage rather than skip. That
   reason is about the *budget*, not about round identity, so the two may be
   separable - but the ADR's text does not distinguish them, and reading it
   as settling round identity too is a live risk.
3. **`%Effect.BudgetExhausted{}` is the one cheap option.** It is a single
   struct built at exactly one call site
   ([`lib/statifier/interpreter.ex:404-415`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L404-L415)), inside `terminal_effects/2`,
   which is called from `macrostep/1` - the one function that *can* see the
   fold's remaining budget if it is threaded out. It answers "how deep did the
   fold get" and nothing else; it does not order or distinguish individual
   rounds.

The acceptance criterion on the bead asks for both ("order the rounds *and*
tell how many ran"), which the `BudgetExhausted`-only option satisfies only
half of.

## Detailed Findings

### 1. `macrostep/1`, the private fold, and where round count lives

`macrostep/1` ([`lib/statifier/interpreter.ex:378-383`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L378-L383)) calls the private
`macrostep/3` and then appends `terminal_effects/2`:

```elixir
def macrostep(%MachineState{} = machine_state) do
  {outcome, machine_state, effects} =
    macrostep(machine_state, [], machine_state.max_macrostep_rounds)

  {machine_state, effects ++ terminal_effects(machine_state, outcome)}
end
```

The fold itself is two clauses ([`lib/statifier/interpreter.ex:438-450`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L438-L450)):

```elixir
defp macrostep(machine_state, effects, 0), do: {:exhausted, machine_state, effects}

defp macrostep(machine_state, effects, rounds_left) do
  case microstep(machine_state) do
    {:quiescent, machine_state, round_effects} ->
      {:quiescent, machine_state, effects ++ round_effects}

    {machine_state, round_effects} ->
      macrostep(machine_state, effects ++ round_effects, spend(rounds_left))
  end
end
```

`spend/1` ([`lib/statifier/interpreter.ex:454-455`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L454-L455)) decrements, with
`:infinity` absorbing. Observations that matter for the design call:

- The budget is a **countdown**, not an ordinal. Rounds spent is
  `max_macrostep_rounds - rounds_left`, and under `:infinity` that expression
  is undefined - `spend(:infinity)` returns `:infinity` forever, so under
  `max_macrostep_rounds: :infinity` there is today **no round count at all**,
  not even derivable. Any ordinal mechanism has to decide what it does under
  `:infinity` (a separate counter that counts up, rather than reusing the
  budget countdown, is the shape that survives `:infinity`).
- `rounds_left` never leaves the fold. The `:exhausted` clause discards it
  (it is matched as the literal `0`), and the `:quiescent` clause never
  reports it. `macrostep/1` therefore cannot today say how many rounds a
  *successful* fold took either - the anonymity is not livelock-specific,
  only livelock-conspicuous.
- The fold's return is a 3-tuple `{:quiescent | :exhausted, machine_state,
  effects}` (`@spec` at [`lib/statifier/interpreter.ex:417-421`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L417-L421)), a shape
  st-sd1 introduced. Threading a rounds-spent value out is a change to this
  private tuple only; `macrostep/1`'s public `{machine_state, [effect]}`
  contract does not have to move.

### 2. Every site that emits a trace or core effect during a round

One round is one `microstep/1` call ([`lib/statifier/interpreter.ex:325-332`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L325-L332)).
Its emission sites, in the order a livelocked round hits them:

| Site | File:line | Effect emitted |
|---|---|---|
| `run_selected/3`, unconditionally | [`lib/statifier/interpreter.ex:515-519`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L515-L519) | `Trace.TransitionsSelected` (including the empty set) |
| `run_selected/3`, non-empty branch | [`lib/statifier/interpreter.ex:526-527`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L526-L527) | `begin_microstep/1`, then `microstep/2`'s own effects |
| `internal_round/1`, `:empty` branch | [`lib/statifier/interpreter.ex:477`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L477) | the terminal eventless probe's `TransitionsSelected` |
| `internal_round/1`, dequeue branch | [`lib/statifier/interpreter.ex:485-494`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L485-L494) | eventless-probe `TransitionsSelected`, then `Trace.EventDequeued`, then selection's `TransitionsSelected` |
| `microstep/2` | [`lib/statifier/interpreter.ex:263-272`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L263-L272) | `Trace.ExitSet`, `Trace.ContentExecuted`, `Trace.EntrySet` (via `ExitEntry`/`Content`) |
| `terminal_effects/2`, `:quiescent` + running | [`lib/statifier/interpreter.ex:394-402`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L394-L402) | `Trace.MacrostepStable` |
| `terminal_effects/2`, `:exhausted` | [`lib/statifier/interpreter.ex:404-415`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L404-L415) | `{:budget_exhausted, %Effect.BudgetExhausted{}}` |
| `exit_interpreter/1` | [`lib/statifier/interpreter.ex:649`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L649), `:671-684` | `Trace.ExitSet`, `Trace.Done`, `{:done, %Effect.Done{}}` |

The st-sd1 livelock shape exercises exactly three of these per round -
`TransitionsSelected(nil)` from the eventless probe, `EventDequeued`
(`from: :internal`) for the `error.execution`, and `TransitionsSelected` for
the selection on that event - which is the "three effects per round" the bead
observes. `microstep/2` never runs in that shape (nothing is enabled), which
is precisely why `begin_microstep/1` is never reached.

Also emitting during a livelocked round, but not into the effect list:
`Selection` enqueues `error.execution` through
`MachineState.raise_platform/4` ([`lib/statifier/interpreter/selection.ex:529`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter/selection.ex#L529))
with `origin: {:transition, t_index}`. That is the `%Event.Cause{}` the bead
reports as identical across all five rounds.

### 3. Why neither counter advances, from `MachineState`'s contract

The counter contract is stated at [`lib/statifier/machine_state.ex:93-122`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L93-L122). The
load-bearing clauses:

> - `begin_macrostep/1` is the **only** writer of `macrostep`: it increments
>   it by one and resets `microstep` to `0`. Its callers are
>   `Statifier.Interpreter.initialize/2`, once ... and
>   `Statifier.Interpreter.handle_event/2`, once per accepted external event
> - `begin_microstep/1` is the **only** writer of `microstep`: it increments
>   it by one. It is called once per *pseudocode microstep* - one
>   exit/execute/enter round ...
> - A selection round that dequeues an internal event enabling no
>   transitions does **not** advance `microstep`: no exit or entry
>   happened, so there was no microstep.
> - Cause metadata and trace effects are both stamped with the counters
>   *as they stand at the moment of the stamp*, i.e. after the `begin_*`
>   call for the step they belong to.

The writers are `begin_macrostep/1` ([`lib/statifier/machine_state.ex:399-401`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L399-L401))
and `begin_microstep/1` (`:410-412`). Their call sites are enumerated in
`Interpreter`'s own moduledoc ([`lib/statifier/interpreter.ex:44-63`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L44-L63)):
`macrostep` is written at `initialize/2` (`:161`) and `handle_event/2`
(`:236`); `microstep` is written at `initialize/2` (`:162`) and at exactly one
other place, `run_selected/3`'s non-empty branch
([`lib/statifier/interpreter.ex:526`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L526)).

So during a livelock:

- No new external event arrives - the whole livelock happens inside one
  `initialize/2` or one `handle_event/2` call - so `begin_macrostep/1` is
  never reached again. `macrostep` is constant.
- Every round's selections are empty, so `run_selected/3` always takes its
  `[]` branch ([`lib/statifier/interpreter.ex:522-523`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L522-L523)) and never reaches
  `begin_microstep/1`. `microstep` is constant.

ADR-0019 states this as the reason the budget counts rounds rather than
microsteps at all ([`docs/adr/0019-macrostep-round-budget.md:35-40`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/adr/0019-macrostep-round-budget.md#L35-L40)):

> - **No microstep ever runs.** No exit or entry happens, so under
>   `MachineState`'s counter contract the `microstep` counter never advances.
>   A bound expressed in microsteps would not catch this loop at all; the
>   bound has to count rounds of the fold - calls of `microstep/1`, empty
>   rounds included.

`max_macrostep_rounds`'s own typedoc repeats it
([`lib/statifier/machine_state.ex:208-216`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L208-L216)): "it is not a microstep count,
because a livelocked fold can run forever without advancing the microstep
counter at all."

The contract also closes with an explicit prohibition
([`lib/statifier/machine_state.ex:120-122`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L120-L122)): "No later function may assign
`macrostep` or `microstep` directly; the contract above is enforced by review
(there being exactly two writer functions), not mechanically." Any mechanism
that tried to fix this by advancing `microstep` per round would break that
contract *and* the spec meaning of a microstep; the three candidates on the
bead all correctly avoid it.

### 4. Every struct that stamps counters today, and what a round field costs

**The stamping paths are two, and both read only `%MachineState{}`.**

*Trace path.* `Effect.trace/3` is a macro ([`lib/statifier/effect.ex:150-160`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L150-L160))
that expands to `payload_module.new(machine_state, fields)` behind the
`machine_state.trace` gate. Every trace payload module defines its own
`new/2`, and the seven bodies are byte-identical apart from the module name:

```elixir
def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
  struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
end
```

([`lib/statifier/effect/trace/transitions_selected.ex:33-35`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/transitions_selected.ex#L33-L35); identically in
`event_dequeued.ex:31-33` and the other five.) There is **no shared stamping
helper** - the convention is documented at [`lib/statifier/effect.ex:89-92`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L89-L92) but
implemented redundantly seven times. The seven structs:

| Struct | `defstruct` today |
|---|---|
| `Trace.ContentExecuted` ([`lib/statifier/effect/trace/content_executed.ex:32`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/content_executed.ex#L32)) | `[:owner, :c_indexes, :macrostep, :microstep]` |
| `Trace.Done` ([`lib/statifier/effect/trace/done.ex:20`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/done.ex#L20)) | `[:donedata, :configuration, :macrostep, :microstep]` |
| `Trace.EntrySet` ([`lib/statifier/effect/trace/entry_set.ex:15`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/entry_set.ex#L15)) | `[:indexes, :macrostep, :microstep]` |
| `Trace.EventDequeued` ([`lib/statifier/effect/trace/event_dequeued.ex:17`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/event_dequeued.ex#L17)) | `[:event, :from, :macrostep, :microstep]` |
| `Trace.ExitSet` ([`lib/statifier/effect/trace/exit_set.ex:22`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/exit_set.ex#L22)) | `[:indexes, :macrostep, :microstep]` |
| `Trace.MacrostepStable` ([`lib/statifier/effect/trace/macrostep_stable.ex:17`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/macrostep_stable.ex#L17)) | `[:configuration, :macrostep, :microstep]` |
| `Trace.TransitionsSelected` ([`lib/statifier/effect/trace/transitions_selected.ex:19`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/transitions_selected.ex#L19)) | `[:t_indexes, :event, :macrostep, :microstep]` |

All seven put `:macrostep`/`:microstep` in `@enforce_keys`.

*Cause path.* `Cause.new/3` ([`lib/statifier/event/cause.ex:84-88`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/event/cause.ex#L84-L88)) is a plain
struct literal taking `origin, macrostep, microstep`. It has exactly two
callers, both in `MachineState`: `raise_internal/4`
([`lib/statifier/machine_state.ex:349-358`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L349-L358)) and `raise_platform/4` (`:382-391`),
each pattern-matching the counters out of the struct head. `Cause` is attached
to an `%Event{}` only through `Event.internal/3` and `Event.platform/3`
([`lib/statifier/event.ex:71-74`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/event.ex#L71-L74), `:82-85`); `Event.external/2` leaves
`cause: nil`.

*Core effects.* All seven core payloads also carry `macrostep`/`microstep`,
but built as struct literals at their call sites rather than through a
constructor: `BudgetExhausted` ([`lib/statifier/effect/budget_exhausted.ex:27-28`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/budget_exhausted.ex#L27-L28)),
`Cancel`, `Done`, `Invoke`, `Log`, `Send`, `SendDelayed`. Only two of the
seven are produced today (`:done`, `:log`, plus `:budget_exhausted` -
[`lib/statifier/effect.ex:41-44`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L41-L44)).

**Costs, by candidate.**

- **A field on `%MachineState{}` (a round ordinal reachable by every stamp).**
  One field, one type entry, one `new/2` default
  ([`lib/statifier/machine_state.ex:174-231`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L174-L231), `:247-265`), plus a writer
  function beside `begin_macrostep/1`/`begin_microstep/1` and a reset rule.
  Then either seven `new/2` bodies each gain a third merged key (and seven
  `defstruct`s a field), or a shared stamping helper is introduced first. This
  is the only mechanism that reaches `%Event.Cause{}`, the trace structs, and
  `BudgetExhausted` with one write. It is also the one that most directly
  collides with ADR-0019 - see section 5.
- **A round ordinal on `%Event.Cause{}` alone.** `Cause` grows one field
  ([`lib/statifier/event/cause.ex:28-29`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/event/cause.ex#L28-L29), plus `@type t` at `:73-77`) and
  `new/3` becomes `new/4` or takes the machine_state. But `Cause`'s two
  callers both live in `MachineState` and read the round from the same struct,
  so this candidate *still requires* the round to be visible on
  `%MachineState{}` - it cannot be threaded from the fold, which is three
  call frames above `Selection.condition_match`'s enqueue site. It also
  distinguishes only rounds that raise an event; a livelock that raises
  nothing (an eventless self-loop that keeps re-enabling) stays anonymous.
- **A round index on the effects the fold emits.** Same reach problem in the
  opposite direction: `Effect.trace/3`'s only argument is the machine_state,
  and the emission sites (`run_selected/3`, `internal_round/1`,
  `ExitEntry`, `Content`) are all below the fold with no round parameter. This
  candidate is either (a) the machine_state field above, or (b) a
  post-processing pass in `macrostep/3` that stamps each round's
  `round_effects` list on the way out - which is possible, because the fold
  already has each round's effects as a separate list before concatenating
  ([`lib/statifier/interpreter.ex:448`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L448)), but would mean rewriting effect
  structs after construction, and would leave `%Event.Cause{}` (which is
  inside an `%Event{}` inside the queue, not in the effect list) untouched.
- **`rounds_spent` on `%Effect.BudgetExhausted{}`.** Cheapest by a wide
  margin: one field on one struct with a single build site
  ([`lib/statifier/interpreter.ex:404-415`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L404-L415)), fed by threading the spent count
  out of `macrostep/3`'s `:exhausted` clause (`:438`). No trace struct, no
  `Cause`, no `MachineState` change, no counter-contract question. But it is
  strictly a depth report; it does not order rounds and does not make round 3
  differ from round 9_000 in the trace. Note also that at exhaustion
  `rounds_spent` is always exactly `max_macrostep_rounds`, i.e. equal to the
  `budget` field already on the struct - so on the exhaustion path alone the
  field is derivable and adds nothing. It only carries information if it is
  also reported on the quiescent path (where the fold ends early), which
  means a shape wider than `BudgetExhausted`.

### 5. What ADR-0012, `docs/observability.md`, and ADR-0019 already promise

**ADR-0012 item 4** ([`docs/adr/0012-debuggability-designed-into-the-core.md:42-44`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/adr/0012-debuggability-designed-into-the-core.md#L42-L44)):

> 4. **Steps are counted and causes are stamped.** machine_state carries
>    monotonic macrostep/microstep counters; trace effects and internally
>    raised events (e.g. `error.execution`) carry the step and the identity of
>    what raised them.

and its consequence (`:53-55`):

> - Deterministic replay stays a property of the session boundary: (machine,
>   initial data, external event log) reproduces a run, and step counters give
>   every trace an ordering key.

"Step counters give every trace an ordering key" is the promise st-ux0 says a
livelock falsifies: within a livelocked fold the key is constant, so it orders
nothing.

**`docs/observability.md` constraint 4** ([`docs/observability.md:110-118`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/observability.md#L110-L118)) is
the detail ADR-0012 makes binding:

> - machine_state carries monotonic counters: macrostep number, and microstep
>   number within the macrostep. They advance in exactly one place each.
> - Every trace effect is stamped with the counters - the ordering key for any
>   timeline UI or log merge.

Note "monotonic" and "advance in exactly one place each": a new round field on
`%MachineState{}` would be a *third* counter with a *third* writer, which the
prose does not currently anticipate. It does not forbid it either - the
sentence constrains the two counters it names.

**Constraint 1** ([`docs/observability.md:26-38`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/observability.md#L26-L38)) is the constraint ADR-0019
leans on to argue the budget is *not* struct state:

> - The machine_state struct reifies everything the spec holds in globals or
>   loop variables: configuration, internal event queue, history values,
>   datamodel, `running` flag, and the step counters from constraint 4. Any
>   machine_state value is a complete, inspectable, resumable position.

**ADR-0019's own decision on where the round count lives**
([`docs/adr/0019-macrostep-round-budget.md:68-74`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/adr/0019-macrostep-round-budget.md#L68-L74)), which is the sentence a
plan must engage directly:

> **The rounds-spent count is a fold-local accumulator**, threaded through
> the private `macrostep/2` (becoming `macrostep/3`) exactly like the effects
> accumulator that already rides there. It is the fold driver's guard, not
> interpreter position, so it does not belong on the struct: constraint 1
> (`docs/observability.md`) reifies the position a stepper resumes from, and
> a human driving `microstep/1` by hand in iex needs no budget - they are
> the bound.

Read carefully, the argument is about **the budget** ("the fold driver's
guard"), and its supporting reason is that a hand-stepping human does not need
a budget. A round *ordinal* is a different object: it is not a guard, it is a
position label, and a hand-stepping human arguably does want to know which
round they are on. Whether that distinction is enough to add a round field to
`%MachineState{}` without amending ADR-0019 is the central open question below.

ADR-0019's Consequences also state the promise st-ux0 reports as weaker than
it looks ([`docs/adr/0019-macrostep-round-budget.md:155-158`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/adr/0019-macrostep-round-budget.md#L155-L158)):

> - The returned machine_state at exhaustion is a live debugging artifact:
>   resume it one `microstep/1` at a time in iex, or run it with
>   `trace: true` and read the repeating `TransitionsSelected` /
>   `EventDequeued` rounds in the effect list.

The resumable half is intact (the returned machine_state genuinely is the
position). The "read the repeating rounds in the effect list" half is what
degrades at 10_000 rounds, and it is the half the bead is filed against.

`docs/observability.md`'s "Where the seams live" table
([`docs/observability.md:154-163`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/observability.md#L154-L163)) names the files any of these mechanisms
would touch: `Statifier.MachineState`, `Statifier.Effect` /
`Statifier.Effect.Trace.*`, and `Statifier.Event.Cause` /
`MachineState.raise_internal/4`.

### 6. The test and fixture surface

**The st-sd1 livelock fixture is inline, not a file.**
[`test/statifier/interpreter/interpreter_acceptance_test.exs:463-587`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/interpreter/interpreter_acceptance_test.exs#L463-L587) owns the
whole thing: `@livelock_document` (`:468`), `livelock_machine/0` (`:477`),
`budget_exhausted/1` (`:479-482`), and five tests driving
`Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)`
(`:496`, `:519`, `:548`, `:582`). They assert
`%Effect.BudgetExhausted{budget: 20}` (`:498-499`, `:586-587`),
`%Effect.BudgetExhausted{microstep: 1}` (`:521`), and
`pending_internal_events` (`:552-553`). No separate SCXML fixture file exists;
a grep for `livelock` outside this module finds nothing.

**Budget tests at the macrostep level**:
[`test/statifier/interpreter/macrostep_test.exs:267-387`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/interpreter/macrostep_test.exs#L267-L387) -
`budget_exhausted_effects/1` (`:267-268`), exact-versus-short round counts
(`:281-338`, `:350-375`), the `trace: false` suppression case (`:383-387`),
asserting `%Effect.BudgetExhausted{budget: 5}` (`:285`) and
`%Effect.BudgetExhausted{macrostep: macrostep, microstep: 5}` (`:321`).

**`max_macrostep_rounds` as configuration**:
[`test/statifier/machine_state_test.exs:159-165`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/machine_state_test.exs#L159-L165) (default 10_000 and override).

**Vocabulary tests that enumerate the whole effect set** - these are the ones a
new field or a new struct would ripple into:
[`test/statifier/effect_test.exs:4`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/effect_test.exs#L4), `:28-29` (table-driven over the vocabulary,
per [`lib/statifier/effect.ex:129-131`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L129-L131));
[`test/statifier/machine_state_acceptance_test.exs:83`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/machine_state_acceptance_test.exs#L83) (field list), `:147-148`,
`:178`, `:184` ("effect union covers the core seven plus all seven trace
points"), `:200` ("trace-off emission yields [] for all seven trace payload
modules").

**Trace struct unit specs**: `test/statifier/effect/trace_test.exs` has a
`describe` per payload `new/2` (`:20`, `:32`, `:55`, `:65`, `:76`, `:86`,
`:98`) - seventeen matches on the three names of interest. A third stamped
field would touch every one of these describes.

**`%Event.Cause{}` assertions**: `test/statifier/event/cause_test.exs` has four
direct `%Cause{...}` assertions (`:13`, `:23`, `:33`, `:43`), each checking
`origin`, `macrostep`, and `microstep` together. `Cause` is aliased or used in
about a dozen other test modules; a broad grep for the three field names across
`test/` returns roughly 80 occurrences in 14 files, most of them counter fields
on trace structs rather than `Cause` itself.

**Trace-asserting test modules and rough match counts** for
`TransitionsSelected`/`EventDequeued`/`MacrostepStable`:
`interpreter_acceptance_test.exs` (24), `macrostep_test.exs` (22),
`trace_test.exs` (17), `microstep_test.exs` (11),
`machine_state_acceptance_test.exs` (6), `entry_test.exs` (6),
`effect_test.exs` (3), `termination_test.exs` (3).

**`test/support/`**: there is **no generic context recorder, trace formatter,
or effect snapshotter**. What exists:
- `test/support/context_recorder.ex` - `Statifier.ContextRecorder`, a test-only
  executable-content node whose `execute/2` returns
  `{:log, %Statifier.Effect.Log{label: ..., value: datamodel_context,
  macrostep: 0, microstep: 0}}` (around `:57-90`). It hardcodes the counters.
- [`test/support/test_content.ex:51`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/support/test_content.ex#L51) - same pattern,
  `%Statifier.Effect.Log{label: label, macrostep: 0, microstep: 0}`.
- [`test/support/case.ex:27-29`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/support/case.ex#L27-L29), `:85-175` - `Statifier.Case`; `initialize/1`
  and `send_event/2` return `{next, effects}`, and `assert_configuration/3`
  (`:121`) / `observed_state_chart/2` (`:138-139`) scan the effect list for
  `{:done, _}` only.

Both hardcoded `%Effect.Log{}` literals matter: `Effect.Log`'s `@enforce_keys`
is `[:macrostep, :microstep]` ([`lib/statifier/effect/log.ex:23-24`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/log.ex#L23-L24)), so a
mechanism that adds an enforced third counter field to the *core* effect
structs breaks these two harness files at compile time. A mechanism confined to
trace structs and/or `BudgetExhausted` does not touch them.

**`test/passing_tests.json`**: no coupling. Grepping it for
`budget|effect|Effect|trace|macrostep_rounds` returns nothing - it is a
registry of test identifiers, not of struct shapes. The regression ratchet is
therefore not in scope for any of the candidates.

**Doctests**: none. `grep "iex>"` under `lib/statifier/effect/` and in
`lib/statifier/interpreter.ex` returns no matches, so no printed-struct
doctest breaks when a field is added.

**Sabotage**: [`docs/testing.md:87-126`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/testing.md#L87-L126) requires every new or changed test
asserting `lib/` behavior to carry a `# sabotage: <what was broken> -> red`
line. Corpus files are exempt; harness plumbing states its exemption. Any new
round-identity test lands under this rule.

### 7. The spec's own position

The REC's Termination note, read from the local cache
(`.git/spec-cache/scxml-rec.html:5645-5647`):

> A microstep always terminates. A macrostep may not. A macrostep that does
> not terminate may be said to consist of an infinitely long sequence of
> microsteps. This is currently allowed.

Appendix D's inner loop (`appendix-d.txt:119-132`) carries `macrostepDone`
and no round counter of any kind. There is therefore **no pseudocode variable**
a round ordinal would be porting: like `macrostep/1` and `microstep/1`
themselves, it is a hoisting artifact of this port, and under ADR-0002 it
would need its own mechanical-reason comment at the site where it is written.
That the spec calls the sequence "an infinitely long sequence of microsteps"
while this engine's counter contract says no microstep ran is worth noting -
the spec's informal "microstep" here is this port's "round".

## Code References

- [`lib/statifier/interpreter.ex:378-383`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L378-L383) - `macrostep/1`, calls the fold then appends `terminal_effects/2`
- [`lib/statifier/interpreter.ex:404-415`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L404-L415) - `terminal_effects/2`'s `:exhausted` clause, the sole `%Effect.BudgetExhausted{}` build site
- [`lib/statifier/interpreter.ex:417-421`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L417-L421) - the private fold's `@spec`, the 3-tuple return shape
- [`lib/statifier/interpreter.ex:438-450`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L438-L450) - the two `defp macrostep/3` clauses; `rounds_left` never escapes
- [`lib/statifier/interpreter.ex:454-455`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L454-L455) - `spend/1`, `:infinity`-absorbing
- [`lib/statifier/interpreter.ex:474-498`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L474-L498) - `internal_round/1`, the livelocked round's `EventDequeued` and second selection
- [`lib/statifier/interpreter.ex:514-530`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L514-L530) - `run_selected/3`, the only `begin_microstep/1` call site outside `initialize/2`
- [`lib/statifier/interpreter.ex:44-80`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L44-L80) - the moduledoc's own restatement of where each counter is written and why traces lag one microstep
- [`lib/statifier/machine_state.ex:93-122`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L93-L122) - the counter contract
- [`lib/statifier/machine_state.ex:174-231`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L174-L231) - `defstruct` and `@type t`, where a round field would go
- [`lib/statifier/machine_state.ex:208-216`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L208-L216) - `max_macrostep_rounds` typedoc, "not a microstep count"
- [`lib/statifier/machine_state.ex:349-358`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L349-L358), `:382-391` - `raise_internal/4` / `raise_platform/4`, the only `Cause.new/3` callers
- [`lib/statifier/machine_state.ex:399-401`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/machine_state.ex#L399-L401), `:410-412` - `begin_macrostep/1`, `begin_microstep/1`
- [`lib/statifier/effect.ex:104-125`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L104-L125) - `@type core` / `@type trace` / `@type t`
- [`lib/statifier/effect.ex:150-160`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect.ex#L150-L160) - the `trace/3` gate macro; `machine_state` is its only data input
- [`lib/statifier/effect/budget_exhausted.ex:27-36`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/budget_exhausted.ex#L27-L36) - the struct a `rounds_spent` field would join
- [`lib/statifier/effect/trace/transitions_selected.ex:33-35`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/effect/trace/transitions_selected.ex#L33-L35) - the `new/2` body repeated verbatim in all seven trace modules
- [`lib/statifier/event/cause.ex:28-29`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/event/cause.ex#L28-L29), `:67-88` - `Cause`'s fields, `origin/0`'s four arms, `new/3`
- [`lib/statifier/event.ex:40-41`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/event.ex#L40-L41), `:71-85` - where `cause` attaches to an `%Event{}`
- [`lib/statifier/interpreter/selection.ex:529`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter/selection.ex#L529) - the livelock's own `error.execution` raise, `origin: {:transition, t_index}`
- [`test/statifier/interpreter/interpreter_acceptance_test.exs:463-587`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/interpreter/interpreter_acceptance_test.exs#L463-L587) - the st-sd1 livelock fixture and its five tests
- [`test/statifier/interpreter/macrostep_test.exs:267-387`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/statifier/interpreter/macrostep_test.exs#L267-L387) - the macrostep-level budget tests
- [`test/support/context_recorder.ex:57-90`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/support/context_recorder.ex#L57-L90), [`test/support/test_content.ex:51`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/test/support/test_content.ex#L51) - the two hardcoded `%Effect.Log{macrostep: 0, microstep: 0}` literals

## Architecture Documentation

- **ADR-0012** makes `docs/observability.md` binding; item 4 is the promise
  under discussion ("step counters give every trace an ordering key").
- **ADR-0019** decided the round budget, chose the effect channel over a tagged
  return or a platform error event, and placed the rounds-spent count in the
  fold rather than on the struct.
- **ADR-0002** governs deviations: a round ordinal has no Appendix D
  counterpart, so wherever it is written needs a mechanical-reason comment,
  the same way `macrostep/1`'s own hoisting comment
  ([`lib/statifier/interpreter.ex:372-377`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/lib/statifier/interpreter.ex#L372-L377)) and the budget guard's comment
  (`:422-437`) do.
- **ADR-0003** keeps the core pure and makes every outcome a returned effect;
  this is why every candidate here is a data field rather than a callback or a
  log.
- **ADR-0005** is why every identity in these structs is an interned integer
  index rather than a string or a struct.

## Historical Context

- `docs/plans/260812-st-sd1-macrostep-round-budget.md` is the plan that built
  ADR-0019. Its "Deferred Manual Verification" section (`:852-867`) is where
  this bead was filed; the summary line reads: "**st-ux0** - during a livelock
  neither counter advances, so the default budget yields ~30,000 byte-identical
  trace effects with no way to order the rounds or read how deep the fold got
  (ADR-0012)."
- The same section records two qualifications from that walkthrough worth
  carrying forward. Phase 1 (`:880-885`): `pending_internal_events` "is always
  empty for this bead's own shape, where each round drains the one event it
  raises" - so on the st-sd1 fixture, `%Effect.BudgetExhausted{}` today carries
  a configuration, a budget, and two constant counters, and nothing else that
  varies. Phase 2 (`:905-913`): the fold's return shape already changed once
  during st-sd1, from `{machine_state, effects}` to the tagged 3-tuple, which
  is precedent for widening it again.
- Phase 3's manual items (`:942-947`) include "Reading the `trace: true` effect
  list by hand shows the repeating round structure" - confirmed at a budget of
  5, which is the scale at which the anonymity is still readable.
- There is no prior research document on observability, tracing, or the
  interpreter loop under `docs/research/`. The nearest prior plans are
  `docs/plans/260809-st-wju.2-machine-state-event-effects-vocabulary.md` (which
  established the effect vocabulary and the `Cause` shape) and
  `docs/plans/260810-st-wju.6-microstep-macrostep-and-interpreter-entry.md`
  (which built `microstep/1`, `macrostep/1`, and the fold).
- st-wju.2's Decision 5 ([`docs/plans/260809-st-wju.2-machine-state-event-effects-vocabulary.md:281-301`](https://github.com/riddler/statifier-ex/blob/1736cf5e4bea4874a81357967c6633c461f1e185/docs/plans/260809-st-wju.2-machine-state-event-effects-vocabulary.md#L281-L301))
  is where the counter contract was argued, including the clause that produces
  this bead's symptom: "A selection round that dequeues an internal event
  enabling no transitions does **not** advance `microstep`: no exit or entry
  happened, so there was no microstep. The consumed event is still visible,
  because the event-dequeued trace effect is emitted at the current counters."
  The same plan defined `Cause` (`:437-456`) with a two-arm `origin` that has
  since grown to four arms, and its manual-verification item (`:516-524`)
  asserted that "origin plus counters plus the Machine's retained `Location` is
  the whole message with no fourth input" - a claim a round ordinal would be
  the fourth input to.

## Related Research

None directly on this topic. `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md`
and `docs/research/260813-st-af3.4-assign-deep-path-vivification.md` touch the
same `raise_platform/4` cause-stamping path from the datamodel side.

## Open Questions

1. **Does ADR-0019's "does not belong on the struct" settle a round ordinal,
   or only the budget?** The ADR's reason is that the rounds-spent count is
   "the fold driver's guard, not interpreter position", and that a human
   hand-stepping needs no budget. A round ordinal is a position label rather
   than a guard, and a hand-stepper plausibly does want it - but the ADR does
   not draw that line, and a mechanism that puts a round field on
   `%MachineState{}` will read as contradicting it unless the plan argues the
   distinction explicitly or amends the ADR. **No human was available to
   resolve this during research; it is left for the plan stage.**
2. **What is a round ordinal under `max_macrostep_rounds: :infinity`?**
   `spend(:infinity)` returns `:infinity`, so rounds-spent is not derivable
   from the budget at all in that mode. A count-up counter survives it; a
   `budget - rounds_left` derivation does not.
3. **Does the ordinal reset per macrostep, or run monotonic per session?**
   `begin_macrostep/1` resets `microstep` to 0; the parallel choice for a round
   field would be a reset there. A session-monotonic round number would instead
   be a global sequence number, which is a different (and arguably more useful
   for log merge) object.
4. **Does the mechanism need to reach `%Event.Cause{}` at all?** The bead's
   acceptance criterion is about the *trace* ordering rounds. `Cause` rides on
   an event, not in the effect list, and is only observable when the event is
   later dequeued and traced - by which point the `EventDequeued` trace effect
   could carry the round itself. Whether `Cause` needs its own round field, or
   inherits legibility from the surrounding trace, is undecided.
5. **Should quiescent and terminating folds report rounds too?** Today no fold
   reports its round count, not just the exhausted one. `Trace.MacrostepStable`
   would be the natural carrier for a stable fold's round count, which would
   also make a `rounds_spent` on `%Effect.BudgetExhausted{}` non-redundant with
   its existing `budget` field (at exhaustion the two are always equal).
6. **Is a shared stamping helper a prerequisite?** The seven trace `new/2`
   bodies are identical today. Adding a third stamped field means editing seven
   copies, or introducing the shared helper first. That is a refactor decision
   the plan should make deliberately rather than by default.
