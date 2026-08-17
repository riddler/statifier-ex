# ADR-0043: Re-entry effects defer to the outer batch

Status: accepted (2026-08-17)

## Context

`Statifier.Session.perform/3` plans an effect list into instructions and
reduces over them; `{:notify, effect}` heads every effect's instruction list,
so subscriber arrival order is exactly fold order. Four instruction paths
cross the ADR-0039 seam mid-fold - `{:raise, ...}`, `{:deliver, :internal,
...}`, `communication_error/4`, and `invoke_error/4` - and all converge on the
private `deliver_internal/6`, which calls
`Statifier.Interpreter.deliver_internal/5` and then calls `perform/3`
**recursively** on the effects that call returns
(`lib/statifier/session.ex:1342-1354`). The nested `perform/3` notifies every
re-entry effect before the outer fold resumes, so the tail of the original
batch is delivered last even though its counters are lower.
`docs/research/260817-st-r6l9-invoke-effect-order-reentry.md` maps the
mechanism; st-r6l9 (mirroring statifier-ui's sui-t36.1) reports the observed
consequences:

1. A subscriber sees non-monotone `(macrostep, round)` arrival order - the
   re-entry keeps the enclosing macrostep and advances `round`, so its effects
   carry higher rounds than the outer batch's unsent tail.
2. More than one `Trace.MacrostepStable` arrives for the same macrostep, and
   the later arrival carries the *lower* round.
3. When the run terminates inside a re-entry, trace effects arrive **after**
   `{:halted, :done}`; a consumer treating `:halted` as end-of-stream silently
   drops the tail.

This is reachable on a fully successful path (an `<onentry>` internal
`<send>`), not only the invoke-failure path it was filed against.

What today's documents promise is narrower than either reading of a fix.
`docs/observability.md` constraint 2 ("same ordering guarantees, same delivery
path") speaks about trace effects relative to other effects *in the same
list*; constraint 4 calls `(macrostep, round)` "the ordering key for any
timeline UI or log merge" without promising delivery order agrees with it.
The session moduledoc (`lib/statifier/session.ex:74-76`) promises `{:halted,
_}` only "following the effects that caused it" - not last.

Two facts weigh on the choice:

- **Replay already produces the monotone order.** ADR-0034's recording is a
  flat ordinal entry list, and its `{:internal, ...}` entry lands *after* the
  entry that triggered it ("interleaved with, not nested inside" -
  `lib/statifier/replay.ex:72-92`). `Statifier.Replay` therefore appends the
  whole outer batch before the re-entry's effects, and
  `test/statifier/replay_round_trip_test.exs` asserts exact ordered stream
  equality between replay and a drained live subscriber. No existing
  round-trip test drives a seam-crossing chart, which is the only reason it
  is green today.
- **ADR-0040 models the same re-entry as a nested telemetry span.** The span
  view is causal by design; the `{:effect, _}` subscriber stream is a flat
  sequence. The two views of one run are structured differently on purpose,
  and ADR-0040 makes no promise about the ordering of effect events relative
  to span events.

The consumer that reported this - statifier-ui's append-only timeline pane -
cannot repair a non-monotone stream itself: sorting a *live* stream needs
both a sort key on every message (only trace payloads and `BudgetExhausted`
carry `round` today) and a watermark saying no earlier-keyed message can
still arrive, which no contract here provides.

## Decision

**1. Monotone arrival is the subscriber-stream contract.** The session
delivers effects to subscribers in non-decreasing `(macrostep, round)` order,
the same order `Statifier.Replay` produces for the same run. Mechanically:
`deliver_internal/6` still crosses the ADR-0039 seam at its instruction's
position - the core's `%MachineState{}` advances immediately, the recording
entry is written at its true position, and the ADR-0040 span opens and closes
around the core drive exactly as today - but the effects the seam returns are
**enqueued, not performed inline**. The outermost `perform/3` drains that
deferral queue FIFO after its own instruction list is exhausted; a deferred
batch that itself crosses the seam appends to the same queue. Because every
re-entry's rounds are higher than the batch that triggered it, FIFO drain is
monotone at any nesting depth, with no sorting anywhere.

The alternative - keep causal/nested delivery and restate `(macrostep,
round)` as a sort key rather than an arrival guarantee - is rejected on
three grounds. It makes live-vs-replay stream equality permanently false for
any seam-crossing chart, breaking the round-trip property ADR-0034 built (a
flat ordinal recording *cannot* reproduce nested order, so the divergence
would be structural, not a bug to fix later). It cannot be consumed: a
sort-key contract without `round` on every effect and without a watermark is
a guarantee no live subscriber can act on. And causal structure is not lost
by deferring - it remains fully available on the channel built for it, the
ADR-0040 nested `[:statifier, :session, :macrostep, :start | :stop]` spans,
which this record leaves untouched. ADR-0040's lean toward nested structure
is an argument about *spans*, and spans keep it.

**2. `{:halted, reason}` is promised as end-of-stream.** The moduledoc's
"one lifecycle message, following the effects that caused it" is strengthened
to: the last message this session sends its subscribers for the run. Decision
1 is what makes it true - the drive that halts is necessarily the last drive
that produces effects, so the batch carrying `{:halt, reason}` drains last,
and `Effects.plan_one/2` already plans the halt instruction after the
`{:done, _}` notify.

The reason no crossing can defer a batch past the halt is stronger than
"a later crossing finds the machine not running", and worth stating exactly,
because the obvious doubt is a crossing sitting *earlier* in the halting
batch than the halt instruction - its deferred batch would drain after
`{:halt, reason}` was already notified. It cannot happen: a core drive runs
to completion before the session performs any of the instructions it
produced, so the halt is already decided by the time the first instruction
is performed, and *every* crossing in the halting batch finds the machine
not running - whatever its position in the list. Verified against the
sharpest case available, a `<send target="#_internal">` in a `<final>`'s
`<onentry>`, where the crossing precedes the `{:done, _}` notify in the same
list: nothing is deferred and `{:halted, :done}` is last. The same
holds for `:cancelled` and `:budget_exhausted`, whose `halt_override` threads
through the same path. The regression suite asserts it rather than trusting
the argument.

**3. More than one `Trace.MacrostepStable` per macrostep is accepted and
documented.** Each one reports a real phase boundary: one core drive
(`main_event_loop/1` call) reaching quiescence, of which a macrostep may
contain several when the session re-enters mid-macrostep. ADR-0032 already
guarantees exactly one terminal effect per drive; this record adds the
uniqueness key a consumer may rely on: **exactly one `MacrostepStable` per
`(macrostep, round)`**, and under decision 1 the last-arriving one within a
macrostep is the macrostep's true quiescence. Suppressing the intermediate
ones at the session boundary is rejected: it would hide a boundary the core
genuinely crossed, and it would diverge from replay, which re-derives the
suppressed effect from the core and would fail stream equality.

**4. Stamping `round` onto core effects is deliberately not decided here.**
Under decision 1 a live subscriber no longer needs a sort key - arrival order
is the guarantee - so the remaining want (offline log merges across streams,
constraint 4's other half) is real but not this bug. Adding a field to a core
effect struct is, by ADR-0040's own consequences ("a field being added to,
removed from, or renamed on any `Statifier.Effect.*` struct" reopens that
record), a contract change with its own blast radius. It is follow-on work,
filed as its own bead, additive when it comes.

**Documentation edits this record directs**, on the implementing branch:
`docs/observability.md` constraint 2 gains the cross-batch sentence (delivery
order to a subscriber is monotone in `(macrostep, round)`, matching replay),
constraint 4 gains the `MacrostepStable` uniqueness key, constraint 6 gains
the end-of-stream promise; the session moduledoc's subscriber-stream section
restates both promises. The deviation is session-side sequencing, not a core
change - no Appendix D function moves - so no new ADR-0002 comment is owed in
the interpreter; `deliver_internal/6`'s definition site cites this record
where the inline `perform/3` call used to be.

## Consequences

- st-r6l9 itself implements: the deferral in `lib/statifier/session.ex`
  (decision 1), the strengthened promises and the documentation edits
  (decisions 2 and 3), and the regression tests - the bead's acceptance
  criterion on the invoke-failure path, the internal-send success path from
  its 2026-08-16 note, and a seam-crossing chart added to the replay
  round-trip suite so `result.stream == stream` guards the property from both
  sides.
- Follow-on beads, not this branch: stamping `round` onto core effects
  (decision 4, reopens ADR-0040 when taken); the `:internal` macrostep span
  opening with `event: nil` (research open question 4), which decision 1
  neither worsens nor fixes; and the stale "not yet produced" vocabulary note
  at `lib/statifier/effect.ex:26-28` (research open question 6), a chore.
- Telemetry ordering shifts with the stream: `Telemetry.effect/3` fires
  inside the same `{:notify, _}` instruction, so effect and trace telemetry
  events follow the deferred order, and a nested macrostep span's `:stop` now
  precedes its own batch's effect events. ADR-0040 promised no inter-event
  ordering, so this is noted rather than amended; a consumer correlating a
  nested span with the effects it produced should use the span's counters,
  not adjacency.
- ADR-0039 is unchanged: the seam stays the single door, crossed at the same
  position; only *when the returned effects are notified* moves. ADR-0034 is
  reinforced: live delivery now matches the order its recording already
  implied. ADR-0029's position-based reconstruction argument for
  `interpret/2` batches is unaffected - `handle_cast({:interpret, _}, _)`
  reaches `perform/3` directly and crosses no seam of its own, though an
  effect *it injects* that raises internally defers like any other.
- **Settled since acceptance**: a nested re-entry - one whose own deferred
  batch crosses the seam again - *is* reachable from a document, so the FIFO
  argument is load-bearing rather than merely defensive.
  `two_level_internal_send_doc/0` in `test/statifier/session_test.exs`
  reaches depth 2: `b`'s `<onentry>` sends `#_internal` "ping", and draining
  that batch enters `c`, whose own `<onentry>` sends "pong" while the first
  entry is still being drained. The chart's ordering assertions would pass at
  one level too, so the evidence is the mutation instead: dropping
  `drain_deferred/1`'s trailing recursion fails that test alone, and the run
  never reaches `d`.
- Open question this record carries rather than settles: whether
  statifier-ui's timeline wants `round` on core effects soon enough to raise
  the follow-on bead's priority - that call belongs to the sui tracker under
  ADR-0025.
- What would reopen this record: a consumer with a demonstrated need for
  causal/nested delivery on the subscriber stream that the ADR-0040 spans
  cannot serve, or a change to ADR-0034's flat recording shape - either would
  re-argue decision 1 rather than adjust it.
