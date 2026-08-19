---
date: 2026-08-19T03:51:19-0600
researcher: Claude
git_commit: f7fcaa83c7835b857ff6ce727df6831f167646e7
branch: st-rsyx-oban-durable-timers
repository: statifier-ex
beads_issue: st-rsyx
topic: "What of the statifier_oban charter (durable timers, async invoke execution) is deliverable inside statifier-ex today?"
tags: [research, codebase, effects, session, timers, invoke, docs]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Research: the statifier_oban charter, and what part of it lands inside this repository

**Date**: 2026-08-19T03:51:19-0600
**Git Commit**: f7fcaa83c7835b857ff6ce727df6831f167646e7
**Branch**: st-rsyx-oban-durable-timers
**Bead**: st-rsyx

## Research Question

st-rsyx charters a new sibling package, `statifier_oban`, covering three
things: consuming `send_delayed` effects into durable Oban jobs, an
Oban-backed invoke-handler base built on the st-cmq.8 handler registry, and
clock discipline. Its acceptance criteria are three clauses:

1. `send_delayed` and cancel round-trip through Oban with uniqueness and
   cancellation correct across a simulated restart;
2. an invoke-handler base ships with idempotency contract documented;
3. the durable-timers pattern is documented for non-Oban hosts.

The central question this document answers: **what part of that charter is
actually deliverable inside `statifier-ex` today, with evidence?** Secondary
questions: precisely what seam a durable-timer host consumes, what the
invoke half already has versus genuinely lacks, whether clock discipline
already holds, and where a durable-timers recipe belongs.

## Summary

**The short answer: clause 3 is deliverable here and nothing else is.**

- **Clause 3 (the durable-timers recipe for non-Oban hosts) is deliverable
  today, with zero changes to `lib/`.** The seam it documents is complete and
  shipping: `{:send_delayed, %SendDelayed{}}` and `{:cancel, %Cancel{}}` are
  public, documented effects in the ADR-0003 vocabulary; a live host observes
  them through `Statifier.Session.subscribe/2,3`; a process-less host gets
  them as the return value of the pure core; and the fired event goes back in
  through `Statifier.Session.send_event/2`. Writing the recipe is an act of
  documentation over existing behavior, not a feature.
- **Clause 1 (Oban round-trip tests across a simulated restart) is not
  deliverable here.** Oban is not a dependency ([`mix.exs:41-56`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/mix.exs#L41-L56) lists only
  `predicator`, `saxy`, `telemetry` at runtime), and the tests test package
  code that does not exist.
- **Clause 2 is already half-satisfied in this repository, by st-cmq.8.** The
  "idempotency contract documented" half shipped: [`docs/extending.md:177-189`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L177-L189)
  and ADR-0051 decision 4 state the at-least-once contract. What is missing is
  only the Oban-backed *base module*, which is package code. There is no
  documentation gap on the invoke half.
- **The charter's clock-discipline bullet describes a property that already
  holds.** No wall-clock read happens anywhere in the pure core; every one is
  at the session/telemetry/session-id boundary. `delay_ms` is a relative
  integer resolved purely at effect time. There is nothing to build, only an
  invariant to keep and (arguably) to state.

Two facts frame the transfer condition. The sibling repo **now exists** -
`/Users/johnnyt/repos/github/statifier_oban`, holding only a `.git`
directory, remote `git@github.com:riddler/statifier_oban` (public, empty,
created 2026-08-19T09:46:34Z), zero commits. Its **beads db does not exist**.
The bead's own transfer condition ("Tracked here until the package repo and
its own beads db exist") is therefore half-met.

The strongest warrant for the whole charter is not new: ADR-0003's
Consequences already name this exact use case -
"Embedders can supply their own effect interpreter (e.g. queue delayed sends
into Oban instead of process timers)" ([`docs/adr/0003-pure-core-with-effects.md:27-28`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/adr/0003-pure-core-with-effects.md#L27-L28)).
The charter is the discharge of a consequence recorded in 2026-08-02 and
never built.

## Detailed Findings

### 1. The delayed-send seam, exactly as it stands

**The effect.** `Statifier.Effect.SendDelayed`
([`lib/statifier/effect/send_delayed.ex:25-54`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L25-L54)) carries every field
`Statifier.Effect.Send` does plus `delay_ms`:

```
@enforce_keys [:event, :delay_ms, :macrostep, :microstep, :round]
defstruct [:event, :target, :type, :data, :send_id, :delay_ms, :c_index,
           :owner, :macrostep, :microstep, :round, id_from_author?: false]
```

`delay_ms` is `non_neg_integer()` - a **relative** duration, never an absolute
deadline ([`lib/statifier/effect/send_delayed.ex:47`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L47)). Its own moduledoc states
the division of labour the charter depends on: "The timer that fires this send
is `Statifier.Session`'s to schedule; this module only defines the shape it
schedules" ([`lib/statifier/effect/send_delayed.ex:5-7`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L5-L7)).

`send_id` is `String.t() | nil`, and `id_from_author?` distinguishes an
author-written `id`/`idlocation` from a generated one
([`lib/statifier/effect/send_delayed.ex:15-17`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L15-L17)).

**What identifies a delayed send.** `send_id`, and nothing else. When the
document wrote no `id`, one is minted from a counter
([`lib/statifier/machine/content/send.ex:383-389`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L383-L389)):

```
defp generate_send_id(machine_state, %Send{id: id}) when is_binary(id), do: {id, machine_state}
defp generate_send_id(%MachineState{send_counter: counter} = machine_state, %Send{id: nil}) do
  machine_state = %{machine_state | send_counter: counter + 1}
  {"send_" <> Integer.to_string(counter + 1), machine_state}
end
```

An author-written id is used verbatim and never advances the counter. The
counter is a plain `%MachineState{}` field ([`lib/statifier/machine_state.ex:349`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L349),
typed at `:422`), session-global and deliberately not shared with
`invoke_counter` ([`lib/statifier/machine_state.ex:169-202`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L169-L202), ADR-0035).

**A sharp edge the charter's "unique per send id" must account for:**
`send_counter` starts at 0 for every `%MachineState{}`. `send_1` is therefore
unique only *within* one chart run. An external job store keying uniqueness on
`send_id` alone would collide across runs; the key has to be scoped by the
session (`ctx.session_id` / `_sessionid`) or by the host's own run id. Nothing
in `lib/` does or could do that scoping, because nothing in `lib/` knows about
the host's store.

**What a cancel looks like.** `Statifier.Effect.Cancel`
([`lib/statifier/effect/cancel.ex:20-30`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/cancel.ex#L20-L30)) carries `send_id` plus
`c_index`/`owner` and the three counters, and nothing else. It is planned to
exactly one instruction ([`lib/statifier/session/effects.ex:206-208`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L206-L208)):

```
defp plan_one({:cancel, %Cancel{send_id: send_id}} = effect, _context) do
  [{:notify, effect}, {:cancel_timers, send_id}]
end
```

Note that `{:cancel_timers, send_id}` is the **instruction** vocabulary, not
the effect vocabulary - see finding 5 for why that distinction matters to the
recipe.

**How the session interprets both today.** `plan_send_delayed/3`
([`lib/statifier/session/effects.ex:270-288`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L270-L288)) runs the same type/target checks
`plan_send/3` does, at *plan* time per 6.2.3, then emits
`{:schedule, send_id, delay_ms, route, event, effect}` with the route riding
along unresolved. `Statifier.Session` performs it at
[`lib/statifier/session.ex:1435-1450`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1435-L1450) - the one `Process.send_after/3` call in
the library, as its own comment says ([`lib/statifier/session.ex:1426-1434`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1426-L1434)):

```
defp perform_instruction({:schedule, send_id, delay_ms, route, event, effect}, state, _override) do
  ref = make_ref()
  timer_ref = Process.send_after(self(), {:statifier_delayed_send, ref, send_id, route, event, effect}, delay_ms)
  %{state | timers: Timers.put(state.timers, send_id, ref), timer_refs: Map.put(state.timer_refs, ref, timer_ref)}
end
```

`ref` is a correlation id the session mints itself, because
`Process.send_after/3` cannot embed its own return value in the message it
delivers. `Statifier.Session.Timers` (`lib/statifier/session/timers.ex`) is
the pure bookkeeping value: `put/3` appends per `send_id` in scheduling order
(`:39-44`), because spec 6.3 says a cancel with a given sendid cancels them
all (`:5-9`); `take/2` pops every ref under an id and returns `{[], timers}`
for an unknown id, a no-op not an error (`:51-60`).

`{:cancel_timers, send_id}` is performed at [`lib/statifier/session.ex:1452-1456`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1452-L1456),
folding `cancel_ref/2` (`:1961-1972`, the `Process.cancel_timer/1` site) over
every ref `Timers.take/2` returned.

**Termination.** `terminate/2` ([`lib/statifier/session.ex:1182-1201`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1182-L1201)) cancels
every live ref `Timers.refs/1` returns, `nil`-id sends included - spec 6.2's
discard-on-termination. A **halted** session is a different case: reaching
`:done` sets `state.halted` but does not stop the process and does not cancel
timers ([`lib/statifier/session.ex:45-57`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L45-L57), `1546-1553`); a pending OS timer
stays live until an explicit `stop/2`. When it fires on a halted session,
`handle_info/2` still runs its bookkeeping but `handle_continue(:drain, ...)`
declines to drain onto a halted session ([`lib/statifier/session.ex:970-973`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L970-L973)),
so the event sits queued.

An externally-scheduled timer deliberately breaks the 6.2 discard guarantee -
that is the entire point of durability. A recipe has to say what replaces it.

### 2. Delivering a fired event back in

**The doors.** Every write door on `Statifier.Session` is a `GenServer.cast`;
there is no synchronous variant of any of them:

```elixir
@spec send_event(server :: server(), event :: Event.t() | String.t()) :: :ok      # session.ex:530-536
@spec send_invoked_event(server :: server(), invoke_id :: String.t(), event :: Event.t()) :: :ok  # :546-549
@spec done_invocation(server :: server(), invoke_id :: String.t(), donedata :: term()) :: :ok     # :580-583
@spec interpret(server :: server(), effects :: [Effect.t()]) :: :ok               # :611-614
@spec cancel(server :: server()) :: :ok                                           # :624-625
```

The read/administrative surface (`session_id/1`, `snapshot/1`, `status/1`,
`invocations/1`, `recording/1`, `subscribe/2,3`, `unsubscribe/2`) is `call`.

**The in-process analogue of what a durable host does.** When the session's own
timer fires, `handle_info/2` ([`lib/statifier/session.ex:1099-1125`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1099-L1125)) records the
firing, forgets the ref, and calls `deliver_fired/4`
([`lib/statifier/session.ex:1823-1833`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1823-L1833)), which resolves the route *now* and, for
`:self`, re-enqueues onto the session's own inbox "exactly as `send_event/2`
does". An external scheduler calling `send_event/2` therefore rejoins the exact
path a native timer rejoins.

**Re-entry (ADR-0044).** Effects produced by a re-entrant internal delivery are
queued rather than performed inline. `deliver_internal/6`
([`lib/statifier/session.ex:1917-1947`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1917-L1947)) advances the `%MachineState{}` at its own
position but appends the resulting effects to `state.deferred`;
`perform/3` (`:1295-1300`) exhausts the triggering batch, then
`drain_deferred/1` (`:1337-1344`) drains FIFO with no sorting. The fired-timer
path is the documented exception that has to drain explicitly, because
`deliver_fired/4` can reach `deliver_internal/6` outside any `perform/3` fold
([`lib/statifier/session.ex:1110-1122`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1110-L1122)). The subscriber-facing guarantee is in the
moduledoc ([`lib/statifier/session.ex:70-83`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L70-L83)): "a subscriber never sees a later
round ahead of an earlier one."

**Round stamping (ADR-0046).** Every core effect, trace effects included,
carries `macrostep`/`microstep`/`round` ([`lib/statifier/effect.ex:52-64`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect.ex#L52-L64)), and
`SendDelayed`'s counters are "as they stood when the send was scheduled, not
when the timer fires" ([`lib/statifier/effect/send_delayed.ex:11-13`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L11-L13)). A host
correlating a fired job back to the chart position that scheduled it reads them
off the effect it stored, not off the delivery.

**Recording and replay (ADR-0029, ADR-0034).** A fired timer is one of five
recorded input clauses (`Recording.put_timer/4`, called at
[`lib/statifier/session.ex:1101`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1101)). `Statifier.Replay` never arms a timer at all:
`{:schedule, ...}` increments a pure pending-credit count
([`lib/statifier/replay.ex:493-499`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/replay.ex#L493-L499)) and `{:cancel_timers, ...}` moves that count
into a `raced` bucket rather than deleting it, modelling
`Process.cancel_timer/1` returning `false` when the message is already in the
mailbox ([`lib/statifier/replay.ex:501-509`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/replay.ex#L501-L509)). A firing with no credit in either
map is `{:error, {:unscheduled_timer_firing, send_id}}`
([`lib/statifier/replay.ex:190-193`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/replay.ex#L190-L193)).

The consequence for a durable host: feeding the fired event back through
`send_event/2` keeps it on the one recorded input path. Injecting effects via
`interpret/2` instead obligates the ADR-0029 fourth input -
"Calling this function does not void the replay guarantee - it obligates the
recording" ([`lib/statifier/session.ex:604-606`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L604-L606)).

### 3. Clock discipline: already true, nothing to build

**Where `delay_ms` is computed.** `resolve_delay/2`
([`lib/statifier/machine/content/send.ex:270-294`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L270-L294)) evaluates `delay`/`delayexpr`
and hands a binary or duration map to `Statifier.Duration.to_ms/1`
([`lib/statifier/duration.ex:64-74`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/duration.ex#L64-L74)), which delegates to
`Predicator.Duration.parse/1` after rewriting a leading `.` to `0.`
([`lib/statifier/duration.ex:82-84`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/duration.ex#L82-L84)). Unparseable input yields
`{:error, {:invalid_delay, value}}`, which falls out of `execute/2`'s `with`
chain as the ADR-0036 argument-failure/discard path
([`lib/statifier/machine/content/send.ex:98-100`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L98-L100), `:119-152`). No clock is read
on any of these paths - it is arithmetic over an already-evaluated value.

**Every time read in `lib/`.** All confined to three boundary sites:

- [`lib/statifier/session/telemetry.ex:285`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/telemetry.ex#L285), `:357`, `:391`, `:395` -
  `System.system_time/0` and `System.monotonic_time/0` for span metadata.
- [`lib/statifier/session.ex:769`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L769), `:1263` - `System.monotonic_time/0` for span
  durations; `:1189`, `:1435-1450`, `:1452-1456`, `:1961-1972` -
  `Process.send_after/3` / `Process.cancel_timer/1`.
- [`lib/statifier/machine_state.ex:522`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L522) - `System.os_time(:millisecond)` inside
  `generate_session_id/0`, the `sess_` UXID mint. Public, but called only from
  the session boundary: [`lib/statifier/session.ex:747`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L747) and a
  `Keyword.get_lazy/3` default at [`lib/statifier/machine_state.ex:465`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L465)
  (ADR-0008 as amended, per the comment at `:503-509`).

There are **no hits under `lib/statifier/interpreter*`, `lib/statifier/machine*`
(beyond that one definition), or `lib/statifier/effect*`.** The charter's
"no wall-clock reads inside chart logic" is a description of the status quo,
not a change request. `send_<counter>` ids confirm the pattern: deterministic,
no timestamp, no CSPRNG ([`lib/statifier/machine/content/send.ex:383-389`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L383-L389)).

### 4. The invoke half: what st-cmq.8 already shipped

st-cmq.8 merged via PR #191. Against the six embedder requirements recorded on
that bead:

**Delivered:**

- *Behaviour against the effect vocabulary, not Session internals.*
  `ctx` "carries no pid, no `%Statifier.MachineState{}`, and no session struct,
  so a handler cannot reach into `Statifier.Session` internals through it"
  ([`docs/extending.md:71-74`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L71-L74)).
- *Async and long-lived invocations.* A whole section:
  [`docs/extending.md:152-175`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L152-L175). `invoke_id` stability across persist/reload is
  stated at `:153-159`; `done_invocation/3` is the documented door at
  `:161-175`.
- *At-least-once starts and idempotency.* [`docs/extending.md:177-189`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L177-L189):
  "`perform/2` **MAY be called more than once for the same `invoke_id`.** ...
  A handler implementing `perform/2` **MUST be idempotent on `invoke_id`.**"
  and "The library performs no deduplication itself, and cannot". ADR-0051
  decision 4 says the same (`docs/adr/0051-...:141-155`).
- *Per-session registration.* [`docs/extending.md:126-150`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L126-L150); ADR-0051 decision 2.
- *A minimal behaviour a package can build on.* Three pure planning callbacks
  plus one optional `perform/2` ([`docs/extending.md:29-41`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L29-L41)), with
  `{:handler, __MODULE__, payload}` the one non-opaque instruction
  ([`docs/extending.md:57-61`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L57-L61)).
- *autoforward + finalize surviving the move.* ADR-0051 decision 6 keeps
  `<finalize>` auto-assign unconditional across types; `:autoforward` and
  `:cancel_invoke` dispatch through the owning invocation's handler
  ([`lib/statifier/session/effects.ex:214-224`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L214-L224), `:337-341`).

**Explicitly deferred, by name, to this charter and its sibling:**

- "**Not shipping the Oban-backed handler base.** Chartered separately as
  `st-rsyx`" ([`docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md:425-427`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md#L425-L427)).
- "**Not shipping the process-less durable stepper.** Chartered as `st-q6xl`.
  This plan makes the contract executable without a Session process; it does
  not build the second executor" (same file, `:428-430`).

**Therefore, of the charter's invoke half:** the idempotency contract clause of
AC 2 is *already documented in this repository*. The only outstanding piece is
the base module itself, which is package code. There is no in-repo
documentation gap on invoke.

One related fact: the only executors today are
`Statifier.Session.perform_instruction/3` and `Statifier.Replay`'s deliberate
no-op performers - and Replay's `{:handler, _, _}` clause is explicitly a
no-op, "a handler's IO is not replayable"
([`docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md:778-783`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md#L778-L783)).
No non-Session durable executor exists.

### 5. Which vocabulary a recipe may be written against

This is the most consequential precision point for clause 3.

There are two vocabularies, and only one is a public contract:

- **The effect vocabulary** ([`lib/statifier/effect.ex:120-147`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect.ex#L120-L147)) - eleven core
  effects plus nine trace effects, one `@type t()` union, fully documented,
  the ADR-0003 seam. `{:send_delayed, %SendDelayed{}}` and
  `{:cancel, %Cancel{}}` are members.
- **The instruction vocabulary** ([`lib/statifier/session/effects.ex:161-174`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L161-L174)) -
  `{:schedule, ...}`, `{:cancel_timers, ...}`, `{:start_child, ...}` and the
  rest. [`docs/extending.md:57-58`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L57-L58) declares it: "The instruction vocabulary a
  planning callback returns is **opaque outside the library**, with one
  exception a handler author needs: `{:handler, __MODULE__, payload}`."

So a recipe telling hosts to intercept `{:schedule, ...}` would be teaching
against a vocabulary the project has already declared opaque. The recipe's
consumption point is the **effect** pair, which the charter's own wording
already picks: "consume the effect, schedule externally, feed the event back."

Two consumption routes exist, both public:

- **Live session:** `Statifier.Session.subscribe/2` or `subscribe/3` with
  `catch_up: true` ([`lib/statifier/session.ex:676-719`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L676-L719)). Every effect is planned
  to a `{:notify, effect}` in its original position
  ([`lib/statifier/session/effects.ex:8-12`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L8-L12)), so the subscriber stream is the
  complete, ordered effect list.
- **Process-less host:** drive `Statifier.Interpreter` directly and read the
  `[effect]` half of the return. [`docs/extending.md:43-49`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L43-L49) already names this
  audience: "This is what lets a durable host that drives
  `Statifier.Interpreter` directly, with no `Statifier.Session` process at all,
  plan invocations the same way `Statifier.Session` does."

`%MachineState{}` is the resumable position such a host persists -
[`docs/observability.md:36-38`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/observability.md#L36-L38) ("Any machine_state value is a complete,
inspectable, resumable position") and `snapshot/1`'s own doc,
"A term copy and nothing more: `MachineState` carries no pid, ref, port, or
fun" ([`lib/statifier/session.ex:628-634`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L628-L634)). Note that **no serialization
function for `%MachineState{}` exists in `lib/`** - no `Jason.Encoder`, no
`to_map`/`from_map`. Persisting it is the host's problem today, and
`st-m5c3` (Machine identity / serialization contract) is the bead that owns
that gap.

### 6. Where a durable-timers recipe belongs

**How the docs are organised.** `docs/extending.md` is the only host-facing,
recipe-shaped top-level doc - it opens "This is a guide for a host application
author" ([`docs/extending.md:3`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L3)) and runs framing, callbacks, worked example,
registration snippet, then rules and gotchas. `architecture.md`,
`datamodel.md`, `observability.md`, `testing.md`, and `workflow.md` are all
explanation-shaped and contributor-facing.

**What architecture.md says about timers.** Its "Sessions and invoke" section
([`docs/architecture.md:124-182`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/architecture.md#L124-L182)) states only that `Statifier.Session` "owns the
outer `while running` loop, the waiting external events, the delayed-send
timers, `<cancel>`'s effect, and the fan-out of the effect stream to
subscribers" (`:126-129`). It never names `Process.send_after` and never
discusses durability.

**The tension for placement.** `docs/extending.md`'s title and scope are
`<invoke>` handlers specifically ("Extending Statifier: `<invoke>` handlers",
`:1`). A `<send delay>` recipe is a different SCXML element and a different
seam - but it is the same audience, and extending.md is the only doc that has
that audience. The options are a new host-facing doc, or widening extending.md
(retitle plus a second top-level section). Recorded as an open question below,
since it is a judgment call with evidence pointing both ways.

**Indexing.** `mix.exs` has **no ExDoc `docs:` key and no `extras:` list at
all** ([`mix.exs:7-28`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/mix.exs#L7-L28); `ex_doc` is only a dep, `:53`), so a new doc file needs
no mix.exs registration. `README.md` links `docs/architecture.md`,
`docs/adr/README.md` (`:6-7`), `docs/workflow.md` (`:35`), and
`docs/extending.md` (`:36-37`) - a new host-facing doc would want a README
link there.

### 7. Charter precedent and the transfer condition

**Precedent: none.** Three charter beads exist, all filed within 17 seconds of
each other on 2026-08-19:

| Bead | Title | Status | Labels |
|---|---|---|---|
| st-rsyx | Charter: statifier_oban - durable timers and async invoke execution | in_progress, P2 | `area:docs` |
| st-q6xl | Charter: statifier_persistence - durable stepper and storage adapters | open, P2 | none |
| st-ewd7 | Charter: extract heartbeats into a reusable keep-alive library | open, P4 | none |

None has produced any in-repo artifact: `git log --all --grep=<id>` is empty
for all three; no `changelog.d/` fragment, no research doc, no plan doc, no
ADR, no code. The only mentions of the charter ids anywhere in the repo are
inbound scope-exclusion pointers from st-cmq.8's own documents
([`docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md:425-430`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md#L425-L430),
`:1142-1143`; [`docs/research/260818-st-cmq.8-handler-registry-invoke.md:671-678`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/research/260818-st-cmq.8-handler-registry-invoke.md#L671-L678)).

st-rsyx is the **only bead in the tracker carrying `area:docs`**, and it is the
only one of the three whose acceptance criteria contain a documentation clause.
That is the mechanical signal that its in-repo half is the recipe.

**The transfer condition, verified directly.**

```
$ ls -la /Users/johnnyt/repos/github/statifier_oban
drwxr-xr-x  .git          # and nothing else
$ git -C .../statifier_oban status --short --branch
## No commits yet on main...origin/main [gone]
$ git -C .../statifier_oban remote -v
origin  git@github.com:riddler/statifier_oban (fetch/push)
$ gh repo view riddler/statifier_oban --json isEmpty,createdAt,visibility
{"createdAt":"2026-08-19T09:46:34Z","isEmpty":true,"visibility":"PUBLIC"}
```

So: **repo exists, remote exists and is empty, beads db does not exist.** The
bead's condition is "until the package repo **and its own beads db** exist" -
half-met.

What the missing half requires: this repo's tracker is dolt-backed and
embedded (`.beads/config.yaml`: `{"database":"dolt","backend":"dolt",
"dolt_mode":"embedded","dolt_database":"statifier_2","project_id":"1b81253b-..."}`),
so the sibling needs its own initialized beads database with its own prefix
and project id, plus a first commit to hold it. Neither the CLAUDE.md
authority table nor the `wurk:*` skills grant any action inside a *different*
repository - every row is scoped to "the issue's worktree branch" in this
checkout. Initializing and populating the sibling repo is therefore outside
any authority an agent currently holds here. See the open questions.

## Code References

- [`lib/statifier/effect/send_delayed.ex:25-54`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/send_delayed.ex#L25-L54) - the `SendDelayed` struct; `delay_ms` is a relative `non_neg_integer()`
- [`lib/statifier/effect/cancel.ex:20-30`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect/cancel.ex#L20-L30) - the `Cancel` struct; `send_id` is the whole identity
- [`lib/statifier/effect.ex:120-147`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/effect.ex#L120-L147) - the public effect vocabulary union
- [`lib/statifier/session/effects.ex:161-174`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L161-L174) - the instruction vocabulary (declared opaque by [`docs/extending.md:57-58`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L57-L58))
- [`lib/statifier/session/effects.ex:206-208`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L206-L208) - `<cancel>` plans to `{:cancel_timers, send_id}`
- [`lib/statifier/session/effects.ex:270-288`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/effects.ex#L270-L288) - `plan_send_delayed/3`; type/target checked at plan time, route resolved at fire time
- [`lib/statifier/session.ex:1435-1450`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1435-L1450) - the one `Process.send_after/3` call in the library
- [`lib/statifier/session.ex:1452-1456`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1452-L1456), `:1961-1972` - `{:cancel_timers, _}` and `Process.cancel_timer/1`
- [`lib/statifier/session.ex:1099-1125`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1099-L1125) - the fired-timer `handle_info/2`, including its explicit `drain_deferred/1`
- [`lib/statifier/session.ex:1823-1833`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1823-L1833) - `deliver_fired/4`; `:self` rejoins the same inbox `send_event/2` writes to
- [`lib/statifier/session.ex:1182-1201`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1182-L1201) - `terminate/2` cancels every live timer (spec 6.2 discard)
- [`lib/statifier/session.ex:530-536`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L530-L536), `:580-583`, `:611-614` - `send_event/2`, `done_invocation/3`, `interpret/2`, all casts
- [`lib/statifier/session.ex:676-719`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L676-L719) - `subscribe/2,3`, the effect-stream door
- [`lib/statifier/session.ex:1295-1300`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1295-L1300), `:1337-1344`, `:1917-1947` - ADR-0044 deferral and FIFO drain
- [`lib/statifier/session/timers.ex:5-9`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session/timers.ex#L5-L9), `:39-44`, `:51-60`, `:78-79` - the pure timer table
- [`lib/statifier/machine/content/send.ex:270-294`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L270-L294) - `resolve_delay/2`
- [`lib/statifier/machine/content/send.ex:383-389`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine/content/send.ex#L383-L389) - `send_<counter>` generation (ADR-0035)
- [`lib/statifier/duration.ex:64-74`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/duration.ex#L64-L74), `:82-84` - delay parsing, no clock read
- [`lib/statifier/machine_state.ex:169-202`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L169-L202), `:349`, `:422` - `send_counter`
- [`lib/statifier/machine_state.ex:503-524`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L503-L524) - `generate_session_id/0`, the one clock read near the core namespace
- [`lib/statifier/replay.ex:493-509`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/replay.ex#L493-L509) - timers as pure credits, no process and no clock
- [`mix.exs:41-56`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/mix.exs#L41-L56) - three runtime deps; no Oban, no Ecto
- [`docs/extending.md:43-49`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/extending.md#L43-L49), `:57-61`, `:152-189` - the process-less host audience, the opaque-instruction rule, async/idempotency
- [`docs/adr/0003-pure-core-with-effects.md:27-28`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/adr/0003-pure-core-with-effects.md#L27-L28) - "queue delayed sends into Oban instead of process timers"
- [`docs/observability.md:36-38`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/observability.md#L36-L38) - machine_state as a resumable position

## Architecture Documentation

- **ADR-0003** is the charter's own warrant, written 2026-08-02, and it names
  Oban explicitly in its Consequences. Nothing in this charter reopens it.
- **ADR-0029** (`Session.interpret/2` stays public) makes the four-input replay
  tuple the price of injecting effects. A durable-timer host that feeds fired
  events through `send_event/2` stays on the three-input path; one that injects
  effects owes the fourth input.
- **ADR-0034** (replay re-drives the core, no process, no timer) is why
  `Statifier.Replay` models timers as credits rather than refs, and why a
  handler's IO is a documented no-op there.
- **ADR-0035** makes the send id a `%MachineState{}` counter - deterministic,
  replay-stable, and *not* globally unique across runs.
- **ADR-0044** fixes the ordering a durable host observes: re-entry effects
  defer to the outer batch, so the subscriber stream never shows a later round
  first.
- **ADR-0046** puts `macrostep`/`microstep`/`round` on every core effect, which
  is the correlation data a stored job carries.
- **ADR-0051** settles per-session invoke handler registration and states the
  at-least-once contract in decision 4.
- **ADR-0008 as amended** is why `delay_ms`, `send_id`, and `invoke_id` are all
  clock-free: an id minted inside the core is always a deterministic counter.

## Historical Context

- [`docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md:425-430`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md#L425-L430)
  scopes this charter out of st-cmq.8 by name, twice, and pairs it with st-q6xl.
  `:1142-1143` lists both as "Downstream, chartered separately".
- [`docs/research/260818-st-cmq.8-handler-registry-invoke.md:671-678`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/research/260818-st-cmq.8-handler-registry-invoke.md#L671-L678) records the
  same split and quotes st-rsyx's own scope back.
- `docs/adr/0051-...:53-56` records that the six embedder requirements on
  st-cmq.8 came "from a production CQRS/Oban host evaluation" - the same
  evaluation that produced this charter.
- [`docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md:522-529`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md#L522-L529)
  is the only place in `docs/` that names `Process.send_after` at all, and it
  does so to argue the seam should stay replaceable.

## Related Research

- `docs/research/260818-st-cmq.8-handler-registry-invoke.md` - the invoke
  handler registry this charter's invoke half builds on
- `docs/research/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md` -
  where the `SendDelayed`/`Cancel` effects came from
- `docs/research/260815-st-cmq.5-external-send-targets-and-scxml-event-io-processor.md` -
  the routing a delayed send resolves at fire time
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  recorded input path a fed-back event must stay on

## Open Questions

1. **May this session, or any agent, populate the sibling repository?**
   `/Users/johnnyt/repos/github/statifier_oban` exists but holds only `.git`.
   The CLAUDE.md authority table is scoped entirely to this checkout's worktree
   branch; no row addresses acting inside another repository, and initializing a
   beads database there is a new tracker, not a task. Treated as unauthorized
   and untouched for this research. A human's call.

   **Settled (2026-08-19):** Yes, on an explicit human ask this session -
   not by an agent deciding it was allowed. `statifier_oban` now holds a mix
   project, a `.gitignore`-only first commit, and a beads database under the
   `sob` prefix. The standing rule is unchanged: no agent acts inside another
   repository without being asked to, and this question was answered by the
   asking, not by the reasoning.
2. **Does the in-repo half warrant its own bead?** st-rsyx is chartered for
   transfer, but AC clause 3 (the durable-timers recipe) is deliverable here and
   will be orphaned if the bead moves before it is written. Splitting an
   `area:docs` bead for the recipe, leaving the charter to transfer intact, is
   the obvious shape - but filing it is a scheduling decision, not a research
   finding.

   **Settled (2026-08-19):** Yes. `st-ifa3` carries the recipe and owns the
   three commits on this branch; `st-rsyx` stays the charter and transfers to
   the `sob` tracker unencumbered.
3. **New doc, or widen `docs/extending.md`?** extending.md is the only
   host-facing recipe-shaped doc and already addresses the process-less durable
   host (`:43-49`), but its title and scope are `<invoke>` handlers
   specifically. Evidence points both ways; not settled here.

   **Settled (2026-08-19):** A new document, `docs/durable-timers.md`.
   `docs/extending.md` keeps its `<invoke>` scope and gained exactly one
   cross-reference sentence.
4. **Does the recipe need an ADR?** ADR-0003's Consequences already sanction the
   pattern by name, which argues no. Against: nothing today states the
   effect-vocabulary-versus-instruction-vocabulary boundary for a *timer*
   consumer, nor what replaces spec 6.2's discard-on-termination when the
   scheduler is external. Those are contract statements, and this project puts
   contract statements in ADRs.

   **Settled (2026-08-19):** Yes - ADR-0054, amended the same day for the
   plan critic's findings.
5. **How should uniqueness be keyed?** The charter says "unique per send id",
   but `send_counter` restarts at 0 per `%MachineState{}`
   ([`lib/statifier/machine_state.ex:349`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/machine_state.ex#L349)), so `send_id` is unique only within a
   run. Scoping by `session_id` or a host run id is required. Whether the recipe
   states that as a rule or the package decides it is unresolved - and it
   partly depends on st-m5c3 (Machine identity / serialization contract), which
   st-q6xl already depends on.

   **Settled (2026-08-19):** Two compound keys, not one, recorded as ADR-0054
   decision 3. Cancellation is `{session scope, send_id}` and legitimately
   matches many rows; deduplication is `{session scope, send_id, macrostep,
   microstep, round, c_index, owner}`. Session scoping is mandatory for the
   reason this question names. The `<foreach>` residual the key cannot resolve
   is filed as `st-q6b6`.
6. **What is the documented substitute for spec 6.2's discard-on-termination?**
   `terminate/2` cancels every pending timer so nothing scheduled survives the
   process ([`lib/statifier/session.ex:1182-1201`](https://github.com/riddler/statifier-ex/blob/f7fcaa83c7835b857ff6ce727df6831f167646e7/lib/statifier/session.ex#L1182-L1201)). An external scheduler
   deliberately inverts that. Whether the recipe prescribes a cancel-on-run-end
   hook, a validity check at fire time, or leaves it to the host is open.

   **Settled (2026-08-19):** A host-side liveness check at fire time, recorded
   as ADR-0054 decision 4: registry lookup first, then `status/1`, discarding
   the message unless the session is live. "Live" excludes a halted session as
   well as a terminated one. Cancel-on-run-end is best-effort only, because the
   node death this feature exists to survive takes any termination hook with it.
7. **Is a "no clock in the core" invariant worth mechanizing?** Finding 3 shows
   it holds today by construction and by review, but nothing in the gate
   enforces it. The charter treats it as a scope bullet; this repo has a habit
   of turning such claims into checks (ADR-0011's guard ledger, `mix gate.check`).
   Not proposed here - noted as unmeasured.

   **Settled (2026-08-19):** Not mechanized, and deliberately not filed.
   ADR-0011 makes gate configuration a human's call on the record, so an agent
   proposing a new gate check here would be the exact move that ADR forbids.
   The invariant holds by construction today and stays a review item.
