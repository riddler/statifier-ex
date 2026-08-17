# ADR-0045: Every core effect carries `round`

Status: accepted (2026-08-17) - amends 0020 in part; amends 0040 in part

## Context

ADR-0020 gave `%MachineState{}` its third counter and stamped it "wherever
the counters already reach the diagnostics surfaces": the nine
`Statifier.Effect.Trace.*` payloads, `%Statifier.Event.Cause{}`, and
`%Statifier.Effect.BudgetExhausted{}`. The other core effects were exempted
by name:

> Every core effect except `BudgetExhausted` is emitted by executable
> content or by `exit_interpreter/1`, both of which run only inside a
> microstep - a round that advanced the `microstep` counter - so the
> existing `(macrostep, microstep)` pair already distinguishes their rounds;
> the anonymous rounds are precisely the ones that emit no core effects.

That argument is true for what it weighed: ordering power *within* the
effect stream of one run, at a time when the counters existed to make a
livelocked trace diffable. Three records that postdate it changed what the
stamp is for. ADR-0034 made a recorded run a first-class artifact. ADR-0040
put every effect struct verbatim into a `:telemetry` event and froze the
counters-are-measurements rule. ADR-0044 stated the subscriber-stream
delivery guarantee in `(macrostep, round)` - and its decision 4 deferred
exactly this question to its own bead, st-xb2b, which this record settles.

The want the exemption cannot serve is offline (`docs/observability.md`
constraint 4 calls `(macrostep, round)` "the ordering key for any timeline
UI or log merge"): merging a recorded effect log with a separately recorded
trace log. A consumer holding an `%Effect.Send{}` stamped
`(macrostep, microstep)` cannot place it within the trace sub-stream,
because `microstep` does not map to `round`. The mapping is not derivable
from the effect itself - rounds that run no microstep are precisely the
ones ADR-0020 built the ordinal for - and recovering it by joining against
trace payloads that carry both counters requires the run to have been
traced at all. Under `trace: false`, the exact configuration in which a
lean core-effect log is the recorded artifact, there is nothing to join
against. Constraint 2 states the consequence plainly: "`round` is carried
by the `Trace.*` payloads and by `BudgetExhausted` today and by no other
effect, so a mixed stream cannot be sorted back into this order once its
arrival order is lost."

ADR-0044 decision 1 removed the *live* half of the want - arrival order is
now monotone in `(macrostep, round)`, so a live subscriber needs no sort
key - and its decision 4 named the remaining offline half real but out of
that record's scope, "additive when it comes", noting that adding a field
to a core effect struct reopens ADR-0040 by that record's own consequence
terms:

> What would reopen this record: ... a field being added to, removed from,
> or renamed on any `Statifier.Effect.*`/`Statifier.Effect.Trace.*` struct.
> The raw struct rides verbatim in every core/trace event's `effect`
> metadata key, so a struct's fields are part of this contract by
> transitivity ...

This record is that reopening, made deliberately rather than ridden past.
One timing fact bears on it, verified against the tracker rather than
assumed: st-cmq.2, the OpenTelemetry bridge whose landing freezes the
ADR-0040 event shapes against breaking change, is still open - no external
consumer has shipped against the current shapes.

## Decision

**Every core effect carries `round`.** The ten payloads that lack it -
`Send`, `SendDelayed`, `Cancel`, `Invoke`, `CancelInvoke`, `Autoforward`,
`Done`, `Log`, `DatamodelChange`, `DatamodelInit` - each gain a
`round :: non_neg_integer()` field, stamped from `%MachineState{}` at their
existing construction sites exactly as `macrostep`/`microstep` are stamped
today, and joining `@enforce_keys` alongside them, matching
`BudgetExhausted`. The exemption list empties; `BudgetExhausted` stops
being an exception because there is no longer a rule to be excepted from.
The stamp's semantics are ADR-0020's counter contract unchanged: an effect
emitted before the fold begins - `DatamodelInit`, and the
initialization-entry effects `initialize/2` performs directly - carries
`round: 0`, which sorts before every real round, as that contract already
defines.

Uniformity over a narrower stamp is deliberate. The reported want is an
`Effect.Send` in a timeline merge, and stamping only the send family would
serve it - but that trades one exemption table for another, and ADR-0040's
st-ii9v amendment already paid to learn that a per-payload footnote a
consumer must consult loses to a rule that fits in one line. After this
record the rule is one line: every effect in the vocabulary, core and
trace, carries `macrostep`/`microstep`/`round`.

**The stamp is the core's, not the session's.** A rejected alternative was
a session-side wrapper attaching `round` at delivery time, leaving the
structs alone and ADR-0040 unopened. It fails on replay: ADR-0034's
`Statifier.Replay` re-derives effects from the core with no session behind
it, so a session-applied stamp would exist in live streams and not in
replayed ones, breaking the stream equality the round-trip suite asserts.
Anything a recorded effect carries must come from where the counters live,
which is `%MachineState{}` and nowhere else. A second rejected alternative
- documenting the trace-join as the offline recipe instead of adding the
field - fails under `trace: false` as the context describes, and makes the
merge contingent on a diagnostic setting.

**ADR-0020 is amended in part.** Its "other six core effects do not gain
the field" paragraph (six at the time; ten by the same rule today) is
withdrawn, including its cost argument that stamping would "widen
`@enforce_keys` on structs the test harness builds literally ... for no
added ordering power": the ordering power is now demonstrably added - it
is the cross-stream merge key - and the literal builds in `test/support/`
gain a `round: 0` key as part of the implementing change. Everything else
in ADR-0020 stands untouched: the ordinal's definition, `begin_round/1` as
its only incrementing writer, the resets, the rejected mechanisms, and the
`%Event.Cause{}` stamp.

**ADR-0040 is amended in part, on its own terms.** Two clauses are
engaged:

- *The struct shape.* The consequence clause quoted above is triggered, and
  the reopening obliges an additive answer or an argued breaking one. This
  one is additive: a new key on a struct breaks no reader of the existing
  keys, whether the struct is pattern-matched off the subscriber stream or
  read out of an event's `effect` metadata. st-cmq.2 has not landed, so
  the freeze the clause protects has no consumer behind it yet - and even
  post-freeze, addition is the direction ADR-0040's own st-ii9v amendment
  calls non-breaking ("adding a metadata key to a published event is
  additive; removing one ... is breaking").
- *The event contract.* ADR-0040's measurements rule already decides where
  the new value goes, with no new argument needed: "counters are numbers,
  so they are measurements, not metadata." `round` therefore joins the
  measurements of every `[:statifier, :session, :effect, kind]` event, and
  the contract's core-effect measurements line loses its exception clause -
  it read "`macrostep`, `microstep`; plus `round` and `budget` for
  `:budget_exhausted` only (the one core effect ADR-0020 stamps with a
  round)" and now reads `macrostep`, `microstep`, `round` uniformly, with
  `budget` still `:budget_exhausted`'s own and `delay_ms` still
  `:send_delayed`'s own. The trace-event and lifecycle rows are unchanged;
  they carried `round` already.

**What this record does not promise: within-round interleave across
separately recorded logs.** `(macrostep, round)` places an effect between
rounds; inside one round, each log preserves its own internal order, and
the interleave of two logs recorded on different channels is not
recoverable by any key this vocabulary could carry. That is constraint 4's
promise met at its own stated granularity, not a gap: the artifact for
full interleave is a single stream, and ADR-0044 already made the
subscriber stream - and the replay stream equal to it - deliver every
effect, trace included, in one monotone sequence.

## Consequences

- The st-xb2b acceptance criterion is met in the "every effect" direction:
  no exemption list survives, so no record has to maintain one.
- ADR-0020's status line gains "amended in part by 0045"; ADR-0040's status
  line gains an amendment note pointing here. Both edits land with this
  record; the amended records' body text stands as written, with this
  record as the narrowing, the same way ADR-0020 narrowed ADR-0019.
- Implementation, sized separately (this record changes no code):
  - `round` field, `@enforce_keys` entry, and `@type` line on the ten
    payload modules under `lib/statifier/effect/`, with their moduledocs'
    counter sentences updated.
  - `round: machine_state.round` at each construction site - the sites in
    `lib/statifier/interpreter.ex`, `lib/statifier/interpreter/datamodel.ex`,
    `lib/statifier/interpreter/exit_entry.ex`, and
    `lib/statifier/machine/content/{send,log,assign,cancel}.ex` that
    already stamp the two counters.
  - `Statifier.Session.Telemetry`'s core-effect measurement clauses each
    gain `round`, read off the payload like the other two; its `@moduledoc`
    contract table is the authoritative copy and updates with them.
  - Documentation edits: `docs/observability.md` constraint 2's "and by no
    other effect, so a mixed stream cannot be sorted back" sentence is
    rewritten to state the new fact (every effect carries the triple, so an
    offline `(macrostep, round)` merge is possible without tracing);
    `lib/statifier/effect.ex`'s moduledoc counter section and
    `BudgetExhausted`'s "carried by the stamp" framing lose their
    single-exception phrasing.
  - Tests: the payload field-list and vocabulary acceptance tests, the
    telemetry measurement assertions, and the `test/support/` literal
    builds (`test_content.ex`, `context_recorder.ex`) gain the field, each
    behavior-asserting test with its sabotage line per `docs/testing.md`.
- st-cmq.2, when taken, consumes the amended contract; nothing here waits
  on it.
- The hot path cost is one more map read per core effect emission and one
  small integer per payload - the same bill ADR-0020 accepted for the
  trace payloads, now paid by effects that are emitted far less often than
  trace effects are.
- What would reopen this record: a demonstrated consumer need for
  within-round interleave across separately recorded logs (the answer
  would be recording one merged stream, not a finer key - but the demand
  would deserve its own record), or a change to the counter triple itself,
  which is ADR-0020's to make.
