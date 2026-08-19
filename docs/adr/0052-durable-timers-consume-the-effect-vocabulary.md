# ADR-0052: Durable timers consume the effect vocabulary

Status: accepted (2026-08-19) - discharges ADR-0003's Consequences for the
delayed-send half; scopes docs/extending.md:57-58's opaque-instruction rule to
the timer consumer; reads ADR-0035's run-local send id as a cancellation key,
not a uniqueness key

## Context

`st-rsyx` charters a sibling package, `statifier_oban`, to survive a
`<send delay>` past the process that scheduled it. Two effects carry the whole
seam: `{:send_delayed, %Statifier.Effect.SendDelayed{}}`
(`lib/statifier/effect/send_delayed.ex:25-54`) and
`{:cancel, %Statifier.Effect.Cancel{}}` (`lib/statifier/effect/cancel.ex:20-30`),
both members of the public effect vocabulary
(`lib/statifier/effect.ex:120-147`). `delay_ms` is a **relative**
`non_neg_integer()` (`lib/statifier/effect/send_delayed.ex:47`); its own
moduledoc states the division of labour a durable host relies on: "The timer
that fires this send is `Statifier.Session`'s to schedule; this module only
defines the shape it schedules" (`lib/statifier/effect/send_delayed.ex:5-7`).
A live host reads both effects off `Statifier.Session.subscribe/2,3`
(`lib/statifier/session.ex:676-719`); a process-less host reads them off the
`[effect]` half of `Statifier.Interpreter`'s return, the audience
`docs/extending.md:43-49` already names. The fired event re-enters through
`Statifier.Session.send_event/2` (`lib/statifier/session.ex:530-536`).

`Statifier.Session` is one executor of that seam, not the seam itself.
`lib/statifier/session.ex:1435-1450` is the library's single
`Process.send_after/3` call, performing the `{:schedule, ...}` instruction a
plan step emits; `lib/statifier/session.ex:1452-1456` is the matching
`{:cancel_timers, ...}` performer. Both are instruction-vocabulary sites
(`lib/statifier/session/effects.ex:161-174`), internal to
`Statifier.Session.Effects`, and neither is what a host outside the library
reads.

ADR-0003's Consequences already named this use case by name, on the day the
effect boundary itself was decided: "Embedders can supply their own effect
interpreter (e.g. queue delayed sends into Oban instead of process timers)"
(`docs/adr/0003-pure-core-with-effects.md:27-28`). This record does not
reopen that sanction. It discharges it with rules ADR-0003 never stated,
because three questions have no recorded answer anywhere in this repository:

1. **Which vocabulary a timer consumer reads.** `docs/extending.md:57-58`
   already declares the instruction vocabulary opaque outside the library,
   with `{:handler, __MODULE__, payload}` the sole exception: "The
   instruction vocabulary a planning callback returns is opaque outside the
   library." Nothing states that rule for the timer case specifically, and
   the charter's own scope wording - "honoring cancel (the cancel_timers
   instruction)" - names the opaque half by mistake, which this record has to
   correct rather than repeat.
2. **How an external store keys a timer.** `send_counter` starts at 0 for
   every `%MachineState{}` (`lib/statifier/machine_state.ex:349`, ADR-0035),
   so `send_1` is unique only within one chart run. Nothing in `lib/` scopes
   it beyond that run, and nothing could: the library has no view of an
   external store.
3. **What replaces spec 6.2's discard-on-termination.** `terminate/2`
   (`lib/statifier/session.ex:1182-1201`) cancels every live timer ref, which
   is how the library satisfies 6.2 today. An external scheduler deliberately
   survives process death - that is the entire point of durability - so
   something else has to stand in for the guarantee 6.2 states.

**This does not contradict ADR-0035's 2026-08-15 amendment** ("cross-session
sendid collision recorded harmless"). That amendment is about in-library spec
conformance: two sessions sharing `send_1` cannot interfere because each
session's own `Statifier.Session.Timers` table (`lib/statifier/session/timers.ex`)
is scoped to that session's process and nothing else ever reads it. An
external store is a single shared namespace with no such separation, so the
same collision that amendment records as harmless inside the library is a
correctness bug outside it - two different runs' `send_1` would address the
same stored row. Decision 3 below states the scoping rule that keeps that from
happening; it is a new rule for a new consumer, not a reopening of ADR-0035's
own conformance claim.

## Decision

**1. A durable-timer host consumes the effect vocabulary, never the
instruction vocabulary.** The two consumption points are
`{:send_delayed, %SendDelayed{}}` and `{:cancel, %Cancel{}}`
(`lib/statifier/effect.ex:120-147`). `{:schedule, ...}` and
`{:cancel_timers, ...}` (`lib/statifier/session/effects.ex:161-174`) remain
opaque, which is `docs/extending.md:57-58`'s existing rule applied to this
consumer rather than a new one. The charter's own scope wording ("honoring
cancel (the cancel_timers instruction)") is corrected by this decision: it
names the opaque half, and the effect - `{:cancel, %Cancel{}}` - is what a
host actually sees.

**2. The fired event re-enters through `Statifier.Session.send_event/2`** for
a live-session host, or through the host's own next `Statifier.Interpreter`
drive for a process-less one. Not through `interpret/2`
(`lib/statifier/session.ex:611-614`): ADR-0029 makes `interpret/2` the fourth
recorded replay input - "Calling this function does not void the replay
guarantee - it obligates the recording" (`lib/statifier/session.ex:605-606`)
- and a host that chooses it takes on that obligation for no gain, because
`deliver_fired/4` (`lib/statifier/session.ex:1823-1833`) already re-enqueues a
`:self` route exactly as `send_event/2` does. A host that *does* pick
`interpret/2` anyway now knows, from this record, exactly what it bought: a
fourth recorded input alongside the three-input tuple `(machine, initial
data, external event log)`.

**3. A stored timer is keyed by two different compound keys, and they are not
the same key.** This is the correction of the charter's "unique per send id":

- **Cancellation key**: `{session scope, send_id}`. It may legitimately match
  more than one stored row - `Timers.put/3` appends per `send_id`
  (`lib/statifier/session/timers.ex:39-44`) and `take/2` pops every ref under
  an id (`lib/statifier/session/timers.ex:51-60`) because spec 6.3 cancels
  them all ("If multiple delayed events have this sendid, the Processor will
  cancel them all," quoted in the module's own moduledoc,
  `lib/statifier/session/timers.ex:5-9`), and an author-written `id` is reused
  verbatim without advancing the counter
  (`lib/statifier/machine/content/send.ex:383-389`). A cancel deletes every
  match; a cancel that matches nothing is a no-op, not an error, mirroring
  `take/2`'s `{[], timers}` on an unknown id.
- **Deduplication key** (the at-least-once concern):
  `{session scope, send_id, macrostep, microstep, round}`, read off the
  `%SendDelayed{}` itself. Those counters are stamped as of scheduling, not
  firing (`lib/statifier/effect/send_delayed.ex:11-13`, ADR-0046), and every
  component is a deterministic counter, so re-executing the same drive after
  a crash produces a byte-identical key and the host's store dedups it.
- **`session scope`** is `ctx.session_id` / spec 5.10's `_sessionid` for a
  live session, or the host's own durable run id for a process-less host.
  Scoping is mandatory, not advisory: `send_counter` restarts at 0 per
  `%MachineState{}` (`lib/statifier/machine_state.ex:349`, ADR-0035), so
  `send_1` collides across runs. The library does not and cannot supply the
  scope, because it has no view of the host's store.

**4. The substitute for spec 6.2's discard-on-termination is a fire-time
liveness check by the host, with cancel-on-run-end as a best-effort
optimization only.** Spec 6.2 requires, quoted verbatim from the local cache
(`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`):

> If the SCXML session terminates before the delay interval has elapsed, the
> SCXML Processor MUST discard the message without attempting to deliver it.

`terminate/2` (`lib/statifier/session.ex:1182-1201`) is how the library
satisfies that MUST today - it cancels every live ref before the process
exits. An external scheduler inverts that by design. A cancel-on-run-end hook
cannot be the guarantee, because the node death that durability exists to
survive takes the hook with it; it is worth running to keep the store tidy,
and it is never load-bearing. The guarantee is enforceable only at delivery:
**before feeding a fired event back, the host MUST establish that the run is
still live, and discard the message without delivering it otherwise.**
"Live" excludes a halted session as well as a terminated one - reaching
`:done` sets `state.halted` without stopping the process or cancelling timers
(`lib/statifier/session.ex:45-57`, the moduledoc's own "`:done` idles the
session; it does not stop it" section), and `handle_continue(:drain, ...)`
declines to drain onto a halted session
(`lib/statifier/session.ex:970-973`), so an event fed to one sits queued
rather than being discarded. `Statifier.Session.status/1` is the read door
for a live host; a process-less host reads it off its own persisted
position.

## Consequences

- This constrains `statifier_oban` before it is written: its uniqueness
  design is decided here, not there. A package that keys stored jobs on
  `send_id` alone, or that treats the cancellation key and the dedup key as
  one key, would be nonconformant with this record on day one.
- The 6.2 guarantee moves from "preserved by construction" to "preserved by a
  host check." That is a real weakening a host must be told about in plain
  words, not a detail to leave implicit: inside the library, `terminate/2`
  makes the discard unconditional; outside it, the discard depends on a host
  remembering to check liveness at delivery time, every time.
- Process-less hosts additionally need a `%MachineState{}` serialization
  contract that does not exist yet - no `Jason.Encoder`, no
  `to_map`/`from_map` anywhere in `lib/`. `st-m5c3` (Machine identity /
  serialization contract) is the bead that owns closing that gap; this record
  states the dependency rather than inventing a format.
- Nothing in `lib/` changes. No conformance result moves, and no `lib/` or
  `test/` file is touched by this record.
- What would reopen this record: a change to what `Statifier.Session.Timers`
  scopes a cancellation to, a change to the counters `SendDelayed` carries
  (ADR-0046's territory), or `st-m5c3` landing a serialization contract that
  makes decision 3's `session scope` derivable from the stored state itself
  rather than supplied by the host.
