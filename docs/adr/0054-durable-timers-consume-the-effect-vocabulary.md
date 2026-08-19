# ADR-0054: Durable timers consume the effect vocabulary

Status: accepted (2026-08-19) - discharges ADR-0003's Consequences for the delayed-send half; scopes docs/extending.md:58-59's opaque-instruction rule to the timer consumer; reads ADR-0035's run-local send id as a cancellation key, not a uniqueness key - amended 2026-08-19 (st-ifa3: decision 2 scoped to self-routed sends; decision 3's dedup key gains the position fields; decision 4's liveness door corrected) - decision 2's recorded gap decided by ADR-0055 (2026-08-19: the limit is standing for `#_parent`/`#_invokeid`/`#_internal`, deferred with a named trigger for the external-session route)

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
`docs/extending.md:44-50` already names. The fired event re-enters through
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

1. **Which vocabulary a timer consumer reads.** `docs/extending.md:58-59`
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
opaque, which is `docs/extending.md:58-59`'s existing rule applied to this
consumer rather than a new one. The charter's own scope wording ("honoring
cancel (the cancel_timers instruction)") is corrected by this decision: it
names the opaque half, and the effect - `{:cancel, %Cancel{}}` - is what a
host actually sees.

**2. A self-routed delayed send re-enters through
`Statifier.Session.send_event/2`; every other route is out of scope for this
ADR.** *(Amended 2026-08-19, st-ifa3 - the original text of this decision
claimed unconditionally that "the fired event re-enters through
`Statifier.Session.send_event/2`". That claim held only for the self-routed
case; it is corrected below.)*

**Scope.** The claim holds for a `<send delay="...">` with **no target**, or a
target that parses to `:self`. That is the case `deliver_fired/4`
(`lib/statifier/session.ex:1829-1833`) handles with its own clause, by
re-enqueuing onto the session inbox exactly as `send_event/2` does. For that
route, and only that route, a host scheduler can substitute `send_event/2` for
the library's own timer and rejoin an identical path.

**Why the other routes are not covered.** The route is derived in the session
at plan time and travels on the **opaque** `{:schedule, ...}` instruction
(`lib/statifier/session/effects.ex:270-288`'s `plan_send_delayed/3` resolves
`send.target` into `:internal`, `:self`, `#_parent`, `#_invokeid`, or an
external session id, and hands the resolved route to `{:schedule, ...}`, never
back onto the `%SendDelayed{}` effect), which decision 1 forbids a host from
reading. A host holding only the effect can see `target` as the author wrote
it, but not the library's resolution of it, and it has no public door
equivalent to `deliver/5` for `#_parent`, `#_invokeid`, or an external session
id: `deliver_fired/4` (`lib/statifier/session.ex:1829-1833`) special-cases only
`:self`; every other route goes through `deliver/5`. Furthermore the *event*
is built inside the session, not by the host: `delivered_event/2`
(`lib/statifier/session/effects.ex:392-399`) stamps `origin`, `origintype`,
and a `sendid` gated on `id_from_author?`, and `#_internal` uses an entirely
different carrier, `internal_event/1` (`effects.ex:414-427`), whose delivery
re-raises through `Statifier.Interpreter.deliver_internal/5` and rebuilds its
`Cause` from the machine's counters at delivery time (ADR-0039 decision 2).

**What a host must therefore do.** A durable-timer host supports delayed
sends whose target is absent or `:self`. For a delayed send with any other
target - `#_parent`, `#_invokeid`, `#_internal`, or an external session id -
the host must **leave the timer to the library** (do not intercept it): the
effect stream is observational, so ignoring a `%SendDelayed{}` costs nothing
and the session's own `Process.send_after/3` still fires it. Reconstructing a
non-self delivery from outside is not supported today, because the host would
have to rebuild a `%Statifier.Event{}` with the `origin`/`origintype`/`sendid`
the library sets and then find a public door that does not exist. **This is an
open gap, recorded rather than solved** - see Consequences.

A process-less host feeds the fired event in as the next
`Statifier.Interpreter` drive's input for a live-session host's counterpart
route; the same target restriction applies for the same reason.

Not through `interpret/2` (`lib/statifier/session.ex:611-614`) either way:
ADR-0029 makes `interpret/2` the fourth recorded replay input - "Calling this
function does not void the replay guarantee - it obligates the recording"
(`lib/statifier/session.ex:605-606`) - and a host that chooses it takes on
that obligation for no gain, because `deliver_fired/4` already re-enqueues a
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
- **Deduplication key** (the at-least-once concern): `{session scope, send_id,
  macrostep, microstep, round, c_index, owner}`, read off the `%SendDelayed{}`
  itself. *(Amended 2026-08-19, st-ifa3 - the original text of this key omitted
  `c_index` and `owner`; both are now mandatory members, for the reason given
  below.)* Those counters are stamped as of scheduling, not firing
  (`lib/statifier/effect/send_delayed.ex:11-13`, ADR-0046), and
  `c_index`/`owner` (`:33-34`) are the send's position inside its
  executable-content block. Every component is a deterministic counter or a
  static position, so re-executing the same drive after a crash produces a
  byte-identical key and the host's store dedups it.

  **Why the position fields are mandatory, not decoration.** Without them the
  key collides whenever one microstep executes two delayed sends that share a
  `send_id` - two `<send id="x" delay="...">` in one `<onentry>` block, since
  an author-written id is used verbatim and never advances the counter
  (`lib/statifier/machine/content/send.ex:383-389`). The library keeps those as
  two live timers (`Timers.put/3` appends, `lib/statifier/session/timers.ex:39-44`);
  a store keyed without `c_index` would silently collapse them into one,
  dropping a timer the state chart expects to fire.

  **Residual collision, stated honestly.** Even with `c_index` and `owner`,
  the key is *not* strictly per-instance. A `<send id="x" delay="...">` inside
  a `<foreach>` body executes once per iteration from the **same** content
  position, in the same microstep, under the same author id - confirmed by
  reading `lib/statifier/machine/content/foreach.ex`'s `run_content/2`
  (around `:326-343`), which folds over the same fixed, document-order
  `c_index` list on every iteration - so every iteration yields an identical
  key and the store dedups genuine distinct timers down to one. The library
  has no per-iteration ordinal on `%SendDelayed{}` to add. **Guidance for a
  host:** do not put an author-written `id` on a `<send delay="...">` inside a
  `<foreach>` if you are running a durable scheduler; let the id be generated,
  and `send_counter` gives each iteration its own `send_1`, `send_2`, ... and
  the key becomes per-instance again.
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
rather than being discarded.

**How "live" is actually observed.** *(Amended 2026-08-19, st-ifa3 - the
original text of this decision named `Statifier.Session.status/1` alone as
the read door; that is corrected below.)* `status/1` is a `GenServer.call`
(`lib/statifier/session.ex:644-645`), so against a **terminated** session it
exits the caller rather than answering - and terminated is precisely the case
the 6.2 substitute exists to catch. The check is therefore two-step, in this
order:

1. **Terminated?** Resolve the session id through the registry:
   `Registry.lookup(Statifier.Registry, session_id)` (ADR-0027 decision 2,
   documented at `lib/statifier/session.ex:155-160`). An empty result means no
   live session under that id - **discard the message**. A host that holds a
   pid rather than an id uses `Process.alive?/1` instead. A host that insists
   on calling `status/1` directly must wrap it so an exit is caught and read
   as "terminated", not propagated - an uncaught exit here turns a required
   discard into a crashed worker.
2. **Halted?** Only once step 1 says a process is there, call
   `Statifier.Session.status/1` and check its `status` field. A halted session
   is live as a process and must still be treated as not-live for delivery.

A process-less host performs both reads off its own persisted position
instead.

## Consequences

- **Non-self-routed delayed sends are not durably schedulable today.** Decision
  2 scopes the contract to a delayed send whose target is absent or `:self`.
  No public door exists to redeliver a `#_parent`, `#_invokeid`, `#_internal`,
  or external-session route from outside the library - the resolved route
  rides on the opaque `{:schedule, ...}` instruction, not on the
  `%SendDelayed{}` effect. This gap is recorded here, not only in the plan
  that produced this amendment, so it is discoverable from the ADR itself.
  *(Decided by ADR-0055, 2026-08-19: standing for
  `#_parent`/`#_invokeid`/`#_internal` on semantic grounds; deferred with a
  named trigger for an external session id.)*
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
