# ADR-0020: A round ordinal joins the step counters

Status: accepted (2026-08-13) - amends ADR-0019 in part - amended in part by
ADR-0046 (2026-08-17: the core-effect exemption is withdrawn; every core
effect carries `round`)

## Context

ADR-0019 bounded `Statifier.Interpreter.macrostep/1`'s fold with a round
budget and promised, in its consequences, that a livelock becomes a readable
artifact: "run it with `trace: true` and read the repeating
`TransitionsSelected` / `EventDequeued` rounds in the effect list." st-ux0
found that half of the promise weaker than it looks. During a livelock of the
kind ADR-0019 exists to catch, neither counter advances - no external event
arrives, so `begin_macrostep/1` is never reached, and every round's selection
is empty, so `begin_microstep/1` is never reached - and therefore every
effect a round emits is byte-identical to the same effect in every other
round. Verified on the st-sd1 fixture at `max_macrostep_rounds: 5`: five
rounds of three effects each, all fifteen stamped `macrostep: 1,
microstep: 1`, and all five dequeued `error.execution` events carrying the
same `%Event.Cause{origin: {:transition, 0}, macrostep: 1, microstep: 1}`.
At the default budget of 10_000 that is ~30_000 effects in which round 3 is
indistinguishable from round 9_000.

That is a direct failure of ADR-0012 item 4's consequence - "step counters
give every trace an ordering key" - inside the exact scenario ADR-0019
turned from an infinite hang into a finite dump. A reader cannot order the
rounds, cannot tell how many ran, and cannot diff one against another.

The anonymity is not livelock-specific, only livelock-conspicuous: no fold
today reports how many rounds it took, including the quiescent and
terminating ones. Round count exists only as `rounds_left`, an argument to
the private `macrostep/3` fold, and nothing that stamps an effect can see
it. Both stamping paths - `Effect.trace/3`'s payload constructors and
`Cause.new/3`'s two callers in `MachineState` - read `%MachineState{}` and
nothing else, so `%MachineState{}` is the sole place a per-round number
could be read from by everything that stamps
(`docs/research/260813-st-ux0-livelock-round-trace-identity.md`).

Putting it there appears to collide with ADR-0019's own sentence: "The
rounds-spent count is a fold-local accumulator ... It is the fold driver's
guard, not interpreter position, so it does not belong on the struct."
Whether that sentence settled only the budget or also a round ordinal is the
question this record decides.

## Decision

**ADR-0019's struct exclusion covers the budget countdown, not a round
ordinal.** The sentence's own reasons reach only the guard: `rounds_left` is
the fold driver's termination condition, and "a human driving `microstep/1`
by hand in iex needs no budget - they are the bound." A round ordinal is a
different object on both counts. It is a position label, not a guard - it
says *which* round this position is in, and decides nothing about stopping -
and the hand-stepper is precisely who wants it: ADR-0019's payoff is
resuming a livelock position one `microstep/1` at a time, and a resumed
position that keeps counting tells the stepper how far into the cycle they
are. Constraint 1 (`docs/observability.md`) argues *for* reifying it, not
against: "which round of this macrostep" is part of the interpreter position
a stepper resumes from, exactly as the two existing counters are. ADR-0019
is amended in part to record this narrowing; its budget decision is
untouched, and `rounds_left` stays a fold-local accumulator.

**`%MachineState{}` gains a third counter, `round`, under the existing
counter contract.** The contract extends symmetrically:

- `new/2` sets `round: 0`. Zero means "no round of the current macrostep's
  fold has begun"; it is never the number of a real round. The
  initialization entry that `initialize/2` performs directly, before the
  fold, is stamped at `round: 0` - it is the pseudocode's
  `enterStates([doc.initial.transition])`, which sits outside the loop the
  rounds count.
- A new `begin_round/1` is the **only** incrementing writer of `round`: it
  increments it by one, once per round - one `Statifier.Interpreter.microstep/1`
  invocation, empty rounds and the terminal quiescent probe included,
  matching `max_macrostep_rounds`' own definition of a round. It lives at
  the head of `microstep/1`, not in the fold, so a human hand-stepping in
  iex advances it identically to the fold - that equivalence is what makes
  it position rather than fold bookkeeping. The first round of a macrostep
  is round 1.
- `begin_macrostep/1` resets `round` to `0`, exactly as it already resets
  `microstep`. The ordinal is per-macrostep, not session-monotonic:
  `macrostep` is already the outer ordering key, so the pair
  `(macrostep, round)` orders every stamp in a session lexicographically,
  and a session-global sequence number would duplicate what the pair
  provides while breaking the "resets with its parent counter" symmetry the
  contract already teaches.

Because the ordinal counts up on its own rather than being derived from the
budget, it is defined under `max_macrostep_rounds: :infinity`, where
`rounds_left` is `:infinity` forever and a `budget - rounds_left` derivation
does not exist. The budget still charges only rounds that continue the fold;
the ordinal counts every round that ran. At exhaustion the two coincide -
`round` equals the spent budget.

**The ordinal is stamped wherever the counters already reach the
diagnostics surfaces**: the seven `Statifier.Effect.Trace.*` payloads,
`%Statifier.Event.Cause{}`, and `%Statifier.Effect.BudgetExhausted{}` each
gain a `round` field, stamped from `%MachineState{}` by the same two paths
that stamp `macrostep`/`microstep` today. No emission site changes and no
value is threaded through the fold - one write in `begin_round/1` reaches
all of them. This settles the bead's acceptance criterion and three of the
research's dependent questions at once:

- *Ordering*: each livelocked round's `TransitionsSelected` and
  `EventDequeued` now carry a distinct ordinal, so round 3 differs from
  round 9_000, rounds diff against each other, and the trace of an
  eventless livelock (one that raises no events at all) is ordered too -
  which a `%Event.Cause{}`-only mechanism would miss.
- *Cause*: `%Event.Cause{}` carries the ordinal because both of its
  builders already pattern-match the counters out of `%MachineState{}`, and
  because the raise-to-dequeue lag is real information: an
  `error.execution` raised by round *k*'s probe is dequeued by round
  *k*+1, and with `round` on both the cause and the `EventDequeued` trace
  that lag is legible instead of invisible.
- *Quiescent and terminating folds report their depth for free*:
  `Trace.MacrostepStable` stamped with `round` says how many rounds a
  stable fold took, `Trace.Done` the same for a terminating one, and
  `%Effect.BudgetExhausted{}`'s stamp is the rounds-spent count - so no
  separate `rounds_spent` field is added to it (at exhaustion it would
  always equal the existing `budget` field, and the stamp already carries
  the number).

The **other six core effects do not gain the field**. Every core effect
except `BudgetExhausted` is emitted by executable content or by
`exit_interpreter/1`, both of which run only inside a microstep - a round
that advanced the `microstep` counter - so the existing
`(macrostep, microstep)` pair already distinguishes their rounds; the
anonymous rounds are precisely the ones that emit no core effects. Stamping
them anyway would widen `@enforce_keys` on structs the test harness builds
literally (`%Effect.Log{}` in `test/support/`) for no added ordering power.

The mechanisms rejected:

- **`rounds_spent` on `%Effect.BudgetExhausted{}` alone.** Cheapest, but it
  answers only "how many ran" and orders nothing - half the acceptance
  criterion - and on the exhaustion path the number is already the `budget`
  field, so on its own it adds nothing at all.
- **A round ordinal on `%Event.Cause{}` alone.** Both `Cause` builders read
  the counters from `%MachineState{}`, so this route needs the struct field
  anyway, and it leaves any round that raises no event anonymous.
- **A stamping post-pass in the fold** (rewriting each round's
  `round_effects` with an index on the way out). It mutates effect structs
  after construction, cannot reach `%Event.Cause{}` (which rides the
  internal queue, not the effect list), and counts nothing for a
  hand-stepper, whose rounds never pass through the fold.
- **Advancing `microstep` per round.** Breaks the counter contract's
  definition of a microstep and the spec's: no exit or entry happened, so
  there was no microstep.

**The ADR-0002 comment.** Appendix D's inner loop carries `macrostepDone`
and no round variable of any kind; the REC's Termination note reads "A
microstep always terminates. A macrostep may not. A macrostep that does not
terminate may be said to consist of an infinitely long sequence of
microsteps. This is currently allowed." The ordinal is therefore a hoisting
artifact of this port with no pseudocode counterpart, like the two counters
before it, and `begin_round/1`'s call site gets a mechanical-reason comment
citing this ADR, the same way the budget guard's comment cites ADR-0019.

## Consequences

- ADR-0012 item 4's consequence is true again in the one scenario that
  falsified it: `(macrostep, round)` is an ordering key that advances every
  round, so a livelocked trace at any budget is ordered, countable, and
  diffable. The mechanism is engine-level - every fold's rounds are
  counted, whatever shape the chart is - which is the bead's second
  acceptance criterion.
- ADR-0019 is amended in part: its struct exclusion is narrowed to the
  budget countdown. Its decision, its rejected candidates, and its
  `rounds_left` accumulator all stand.
- ADR-0012 itself needs no amendment - a third counter is additive under
  "steps are counted and causes are stamped". `docs/observability.md`
  constraint 4 names two counters and "exactly one place each"; the
  implementation updates that prose to name three (with `begin_macrostep/1`
  resetting the two child counters, as it already does for `microstep`),
  alongside `MachineState`'s counter-contract moduledoc and
  `max_macrostep_rounds`' typedoc.
- One field and one writer on `%MachineState{}`; a `round` field on the
  seven trace payloads, `%Event.Cause{}`, and `%Effect.BudgetExhausted{}`.
  Whether the seven identical trace `new/2` bodies grow a third merged key
  in place or a shared stamping helper is introduced first is the
  implementing plan's call, not this record's.
- The test surface ripples where the research mapped it: the per-payload
  `new/2` describes in `trace_test.exs`, `cause_test.exs`'s four
  assertions, the vocabulary and field-list acceptance tests, and the
  st-sd1 livelock tests, which can finally assert that round *n* and round
  *n*+1 differ. The `test/support/` `%Effect.Log{}` literals are untouched
  because core effects other than `BudgetExhausted` do not carry the field.
- The hot path pays one integer increment per round on top of ADR-0019's
  decrement, and trace payloads carry one more small integer. Nothing else
  changes when `trace: false`.
