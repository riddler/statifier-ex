---
date: 2026-08-15T09:43:36-0600
researcher: Claude
git_commit: b52208e6f8d1aaa1be70427b803fa97d0a4f6824
branch: st-dtm-replay-recorder
repository: statifier-ex
beads_issue: st-dtm
topic: "How a replay recorder attaches at the Statifier.Session input boundary and what the four-input recording must capture"
tags: [research, codebase, session, replay, observability]
status: complete
last_updated: 2026-08-15
last_updated_by: Claude
---

# Research: the replay recorder at the session input boundary (st-dtm)

**Date**: 2026-08-15T09:43:36-0600
**Git Commit**: b52208e6f8d1aaa1be70427b803fa97d0a4f6824
**Branch**: st-dtm-replay-recorder
**Bead**: st-dtm

## Research Question

st-dtm builds the replay recorder ADR-0029 obligated: a recorder attached on
the input side of `Statifier.Session` that captures the four-input recording -
(machine, initial data, external event log, `interpret/2` batches) - in the
session's serialized input order, plus a replayer that proves the recording
round-trips. This document maps the boundary as it exists today: where the
inputs cross, what is already deterministic, what is not, and which existing
patterns and gate rules constrain where the new code can live.

## Summary

The session's input boundary is **five clauses in one module**, all of them in
`lib/statifier/session.ex`, and all but one of them a GenServer mailbox entry:

| Input | Where it crosses | Recording input |
|---|---|---|
| machine + options | `init/1` ([`lib/statifier/session.ex:289-307`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L289-L307)) | 1 and 2 |
| `send_event/2` | `handle_cast({:enqueue_event, event}, _)` ([`lib/statifier/session.ex:363-365`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L363-L365)) | 3 |
| `cancel/1` | `handle_cast(:enqueue_cancel, _)` ([`lib/statifier/session.ex:367-369`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L367-L369)) | 3 |
| timer firing | `handle_info({:statifier_delayed_send, ...}, _)` ([`lib/statifier/session.ex:383-392`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L383-L392)) | 3 |
| `interpret/2` | `handle_cast({:interpret, effects}, _)` ([`lib/statifier/session.ex:371-373`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L371-L373)) | 4 |

Four findings shape the work:

1. **The inbox is one step too deep to be the tap.** ADR-0029 rules out the
   subscriber stream because `Session.Effects.plan/1` cannot distinguish
   derived from injected effects. The same argument reaches one level further
   in: a targetless `:send` effect plans to `{:enqueue_event, event}`
   ([`lib/statifier/session/effects.ex:50-52`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L50-L52)) and re-enters through the same
   `Inbox.enqueue_event/2` a caller's `send_event/2` uses
   ([`lib/statifier/session.ex:472-474`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L472-L474)), so the inbox holds derived and
   delivered events with nothing separating them either. The five clauses in
   the table above are the boundary; `Statifier.Session.Inbox` is not.

2. **The core is already deterministic except for one value.** The single
   nondeterministic input reachable from `Interpreter.initialize/2` is the
   session id: `MachineState.new/2` calls `UXID.generate!(prefix: "sess")`
   when `:session_id` is absent ([`lib/statifier/machine_state.ex:386`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L386)).
   Everything else the core mints is a pure counter by deliberate design -
   the `<invoke>` id is `machine_state.invoke_counter`, chosen over UXID for
   exactly this reason ([`lib/statifier/interpreter.ex:1362-1406`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L1362-L1406), whose
   comment says "A pure counter replays identically"). Events carry no
   timestamp or generated id ([`lib/statifier/event.ex:44-56`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/event.ex#L44-L56)), and neither
   `%MachineState{}` nor `%Machine{}` holds a pid, ref, port, or fun
   ([`lib/statifier/session.ex:250-251`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L250-L251)).

3. **Nothing in `lib/` reads a clock.** [`docs/observability.md:154`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/observability.md#L154) says the
   recording captures inputs "with session timestamps", but the only
   non-pure runtime call anywhere in the library is `make_ref/0` at
   [`lib/statifier/session.ex:484`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L484) and the `Process.send_after/3` beside it.
   There is no `System.monotonic_time`, `DateTime.utc_now`, or `:os.timestamp`
   call in `lib/statifier/` at all. Timestamps are a thing the recorder would
   have to introduce, not a thing it can read off existing values.

4. **Where the recorder may live is constrained by the gate, not just by
   taste.** `Mix.Statifier.AdrGuard` treats `use GenServer`, `GenServer.`,
   `Process.send/send_after/exit/monitor`, `File.`, `spawn`, `receive do`, and
   friends as side effects anywhere under `lib/statifier/`
   ([`lib/mix/statifier/adr_guard.ex:93-98`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L93-L98)), with exactly one allowlisted
   path: `@effect_interpreter_paths ["lib/statifier/session.ex"]`
   ([`lib/mix/statifier/adr_guard.ex:74`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L74)). A recorder shaped like `Inbox` or
   `Timers` - a pure value threaded through session state - passes the guard
   with nothing to argue. A recorder that is itself a process, or that writes
   a file, is a finding unless the added line cites an ADR number or the word
   "deviation" ([`lib/mix/statifier/adr_guard.ex:107`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L107)).

## Detailed Findings

### The five input clauses

`Statifier.Session` is a `use GenServer, restart: :transient`
([`lib/statifier/session.ex:100`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L100)) whose client functions are all casts, which
is what makes the input order total and observable:

- `send_event/2` ([`lib/statifier/session.ex:199-203`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L199-L203)) casts
  `{:enqueue_event, event}`; a binary name is widened to
  `Event.external/2` on the client side, so the server clause always sees a
  `%Event{}`.
- `interpret/2` ([`lib/statifier/session.ex:232-234`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L232-L234)) casts
  `{:interpret, effects}`, an arbitrary `[Effect.t()]`.
- `cancel/1` ([`lib/statifier/session.ex:245`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L245)) casts `:enqueue_cancel`, which
  appends the cancel marker to the same queue as events
  ([`lib/statifier/session/inbox.ex:41-43`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/inbox.ex#L41-L43)) - already an ordered queue entry,
  as the bead notes.
- The fired timer arrives as `{:statifier_delayed_send, ref, send_id, event}`
  ([`lib/statifier/session.ex:383-392`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L383-L392)), forgets the ref, and enqueues the
  event on the ordinary inbox.
- `init/1` ([`lib/statifier/session.ex:289-307`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L289-L307)) takes `{machine, opts}`, runs
  `Interpreter.initialize/2` to quiescence, and performs the resulting
  effects before the first `{:continue, :drain}`.

`snapshot/1`, `status/1`, `session_id/1`, `subscribe/2`, `unsubscribe/2` are
calls that do not mutate core state; `stop/2` ends the process and cancels
outstanding timers ([`lib/statifier/session.ex:406-417`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L406-L417)).

### Why the tap cannot be the inbox

`Session.Effects.plan/1` emits `{:notify, effect}` for every effect in its
original position ([`lib/statifier/session/effects.ex:45-47`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L45-L47)) - ADR-0029's
reason the subscriber stream is not the recording. The same erasure happens on
the input side one level down:

- `{:send, %Send{target: nil}}` plans to `{:notify, effect}` plus
  `{:enqueue_event, Event.external(...)}` ([`lib/statifier/session/effects.ex:50-52`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L50-L52)).
- The session performs that instruction with
  `Inbox.enqueue_event(state.inbox, event)` ([`lib/statifier/session.ex:472-474`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L472-L474)) -
  byte for byte the call `handle_cast({:enqueue_event, ...})` makes
  ([`lib/statifier/session.ex:363-365`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L363-L365)).
- A fired timer takes the same call again ([`lib/statifier/session.ex:388`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L388)).

So the inbox contains, indistinguishably: caller-delivered events, timer
firings, and events the core derived from a targetless `<send>`. Replay
re-derives the third and re-injects the first two. The session's own comment
at [`lib/statifier/session.ex:377-381`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L377-L381) names all three paths converging
deliberately ("so a caller's send, a self-targeted send re-enqueued from an
effect, and a fired timer all reach the core through the one recordable input
path"), which is the property the recorder needs and simultaneously the reason
it must attach above the inbox rather than inside it.

Timer firings are the interesting member of the middle category: the schedule
is derived (a `:send_delayed` effect the core or an `interpret/2` caller
produced), but the firing's *position in the serialized order* is wall-clock,
so it is an input, exactly as the bead states.

### Input 1 and 2: machine and initial data

`start_link/2` splits `:name` off for `GenServer.start_link/3` and passes the
rest into `init/1` ([`lib/statifier/session.ex:181-184`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L181-L184)). `init/1` then narrows
the options to the four `MachineState.new/2` reads
([`lib/statifier/session.ex:290`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L290)):

    machine_opts = Keyword.take(opts, [:session_id, :trace, :datamodel, :max_macrostep_rounds])

Those four are the whole of "initial data" for replay purposes
([`lib/statifier/machine_state.ex:384-407`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L384-L407)):

- `:session_id` - default `UXID.generate!(prefix: "sess")`, lazily
  ([`lib/statifier/machine_state.ex:386`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L386)). The one value that differs run to
  run.
- `:datamodel` - default `%{}`, string-keyed at every level or `ArgumentError`
  ([`lib/statifier/machine_state.ex:387`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L387), `:421-425`).
  `SystemVariables.initial/2` is merged **over** it
  ([`lib/statifier/machine_state.ex:398`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L398)), writing `_sessionid`, `_name`,
  `_event`, `_ioprocessors`
  ([`lib/statifier/evaluator/system_variables.ex:51-60`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/evaluator/system_variables.ex#L51-L60)), so the author map can
  never shadow a system variable and the session id reaches the datamodel by
  that path.
- `:trace` - default `false` ([`lib/statifier/machine_state.ex:404`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L404)). Two runs
  compared for effect-stream equality must set it identically, since the
  emission gate builds nothing when off ([`lib/statifier/effect.ex:161-173`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L161-L173)).
- `:max_macrostep_rounds` - default `10_000`
  ([`lib/statifier/machine_state.ex:405`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L405)), read-only after construction
  (ADR-0019).

`:subscribers` ([`lib/statifier/session.ex:295`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L295)) and `:name`
([`lib/statifier/session.ex:182`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L182)) are runtime placement options, not inputs to
the core's trajectory.

The session never mints the session id itself; it reads it back off
`machine_state.datamodel["_sessionid"]` after `initialize/2` returns
([`lib/statifier/session.ex:300`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L300), documented at `:173-176`). A recorder
therefore has a resolved session id available even when the caller supplied
none - it is on the struct by the time `init/1` builds `%State{}`.

### Input 3 and 4: what the log has to hold

The serialized order is the mailbox order of the four post-init clauses. Each
entry the recording needs is already a plain term:

- `%Event{}` - `name`, `type`, `data`, `cause`, `invokeid`, nothing else
  ([`lib/statifier/event.ex:44-45`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/event.ex#L44-L45)); no timestamp, no generated id
  ([`lib/statifier/event.ex:65-97`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/event.ex#L65-L97)).
- The cancel marker - a bare `:cancel` atom in the inbox
  ([`lib/statifier/session/inbox.ex:24-26`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/inbox.ex#L24-L26)).
- A timer firing - the `%Event{}` carried in the message, plus the `send_id`
  and correlation `ref`. The `ref` is a `make_ref/0` value
  ([`lib/statifier/session.ex:484`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L484)) and is the one non-serializable term
  anywhere near the boundary; the event beside it is plain.
- An `interpret/2` batch - a `[Effect.t()]` list. Every effect struct in the
  family is plain data: no field in any of the nine core structs
  (`lib/statifier/effect/*.ex`) or nine trace structs
  (`lib/statifier/effect/trace/*.ex`) is typed as a pid, reference, or fun.
  `Effect.t()`'s union is closed at [`lib/statifier/effect.ex:113-138`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L113-L138), and
  `Effect.trace?/1` ([`lib/statifier/effect.ex:146-148`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L146-L148)) splits trace from core
  on the tag alone.

### Determinism: what replays identically today

The pure path is `(machine_state, event) -> {machine_state, [effect]}`, and
all of `initialize/2` ([`lib/statifier/interpreter.ex:217-219`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L217-L219)),
`handle_event/2` (`:429-431`), `cancel/1` (`:771-773`), `microstep/1`
(`:852-853`), and `macrostep/1` (`:916`) are pure over their arguments.

Deterministic by construction:

- **Step counters.** `begin_macrostep/1`, `begin_microstep/1`, `begin_round/1`
  are the sole writers of `macrostep`, `microstep`, `round`
  ([`lib/statifier/machine_state.ex:601-631`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L601-L631)), and every trace payload's
  `new/2` stamps all three from the current state (ADR-0020). Two runs over
  the same inputs stamp the same counters.
- **Invoke ids.** `generate_invoke_id/3`
  ([`lib/statifier/interpreter.ex:1385-1406`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L1385-L1406)) uses the pure
  `invoke_counter` field, with the comment at `:1370-1384` recording that
  UXID was rejected here because it "reads the wall clock and a CSPRNG".
- **Effect payloads.** No effect field is derived from wall-clock time.
  `BudgetExhausted` is the one core effect carrying `round`
  ([`lib/statifier/effect/budget_exhausted.ex:30-47`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect/budget_exhausted.ex#L30-L47)); the other eight carry
  `macrostep`/`microstep` only.

Not deterministic, or not obviously so:

- **The session id** when `:session_id` is omitted
  ([`lib/statifier/machine_state.ex:386`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L386)). A recording that captures the
  resolved id and a replay that passes it back reproduces `_sessionid`,
  `_ioprocessors`, and any expression that reads them.
- **`MapSet.to_list/1` on history-recorded states** at
  [`lib/statifier/interpreter/exit_entry.ex:465`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter/exit_entry.ex#L465) and
  [`lib/statifier/interpreter/selection.ex:128`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter/selection.ex#L128), which feed entry ordering and
  therefore effect ordering. Iteration order is a function of set contents on a
  given BEAM build, so it is stable within a run pair on one runtime, but it is
  not an explicit document-order sort the way
  [`lib/statifier/interpreter.ex:503`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L503) is.
- **`send_id` generation** for `<send>` without an id: no producer exists yet
  ([`lib/statifier/effect.ex:47-48`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L47-L48) - "nothing in this core sends, delays, or
  cancels a delayed send yet"), so the mechanism that would have to be
  deterministic is not written. Today every `:send_delayed` and `:cancel` in a
  live session arrives through `interpret/2`.

### Replaying against a live session: the re-scheduling seam

If the replayer drives a fresh `Statifier.Session` and re-injects a recorded
`interpret/2` batch containing `{:send_delayed, ...}`, the session plans it to
`{:schedule, send_id, delay_ms, event}`
([`lib/statifier/session/effects.ex:58-60`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L58-L60)) and arms a real timer with
`Process.send_after/3` ([`lib/statifier/session.ex:483-494`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L483-L494)). The recording also
holds the original firing as a log entry. Unless the replay path suppresses one
of the two, the replayed run receives that event twice - once injected at its
recorded position, once when the re-armed timer fires at wall-clock time. The
bead's own framing ("replay must reproduce firing order and relative timing,
not re-wait the delays") points at the same seam from the other side. Nothing
in the current code resolves it; see Open Questions.

Related mechanics the replayer meets:

- `terminate/2` cancels every live timer on stop
  ([`lib/statifier/session.ex:406-417`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L406-L417)), per spec 6.2.
- A halted session queues ordinary events without draining them, but always
  drains a `:cancel` ([`lib/statifier/session.ex:317-333`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L317-L333)).
- `:done` and `:cancelled` both run `exit_interpreter/1`, which empties
  `configuration`; `status/1` reads the terminal configuration off the retained
  `%Effect.Done{}` instead ([`lib/statifier/session.ex:88-92`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L88-L92), `:553-571`).
  A terminal-snapshot comparison has to account for that, or compare
  `%MachineState{}` values from `snapshot/1` which have the same emptying
  applied to both sides.

### Where new code can live

Precedent inside the session family:

- `Statifier.Session.Inbox` (`lib/statifier/session/inbox.ex`),
  `Statifier.Session.Timers` (`lib/statifier/session/timers.ex`), and
  `Statifier.Session.Effects` (`lib/statifier/session/effects.ex`) are all pure
  values or pure functions, deliberately split out so that "only the performing
  half lives here" ([`lib/statifier/session.ex:8-14`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L8-L14)). Each has a colocated unit
  test (`test/statifier/session/{inbox,timers,effects}_test.exs`), which is the
  naming precedent a `test/statifier/session/recorder_test.exs` would follow.
- `Inbox` and `Timers` are `@opaque t` structs held as fields on
  `Session.State` ([`lib/statifier/session.ex:112-137`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L112-L137)), with `@enforce_keys`
  requiring them at construction (`:115`). A recorder threaded the same way is
  a fourth such field.
- `start_link/2`'s option handling ([`lib/statifier/session.ex:181-184`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L181-L184)) already
  demonstrates the shape a `:record`-style option would take: split what the
  process layer needs, pass the rest to `init/1`.

Gate rules bearing on placement:

- `Mix.Statifier.AdrGuard.effects_findings/1`
  ([`lib/mix/statifier/adr_guard.ex:257-268`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L257-L268)) flags `@effect_call_pattern`
  matches on added lines under `@core_prefix "lib/statifier/"`
  (`:68`) unless the path is in `@effect_interpreter_paths`
  (`:74`, today just `lib/statifier/session.ex`). The pattern covers
  `use GenServer`, `GenServer.`, `Process.(send|send_after|exit|monitor)(`,
  `:timer.`, `Logger.x(`, `IO.(puts|write|inspect)(`, `File.x(`, `System.cmd(`,
  `Node.x(`, `:ets.`, `Agent.x(`, `Task.(start|async)(`, `spawn*(`, and
  `receive do` (`:93-98`).
- The escape is a citation: a line matching `ADR-0\d{3}` or `deviation`
  ([`lib/mix/statifier/adr_guard.ex:107`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L107)) clears the finding.
- `@uxid_adhoc_pattern` ([`lib/mix/statifier/adr_guard.ex:102-105`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L102-L105)) also flags
  `System.unique_integer(`, `:erlang.unique_integer(`,
  `:crypto.strong_rand_bytes(`, and UUID generators - relevant if a recording
  ever wants an id of its own.

Test-tree code is outside `@core_prefix`, so a replayer that lives in
`test/support/` meets none of these rules. `test/support/` already holds
harness modules of that kind - `case.ex`, `context_recorder.ex`,
`feature_detector.ex`, `tmp_dir.ex`.

### Test patterns the round-trip proof would follow

From `test/statifier/session_test.exs` and its siblings:

- Compilation helper `compile!/1` ([`test/statifier/session_test.exs:12-18`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L12-L18))
  runs Parser -> Lowering -> Validator -> Compiler; SCXML fixtures are private
  heredoc functions (`:20-32`, `:45-63`, `:65-73`, `:75-81`).
- Sessions are started with `Session.start_link/2` directly - no
  `start_supervised` - with options seen in tests including
  `subscribers: [self()]`, `trace: true` (`:217`),
  `session_id: "sess_fixed"` (`:125`), and `max_macrostep_rounds: 5` (`:513`).
  The fixed-session-id test is the existing precedent for pinning the one
  nondeterministic input.
- Subscriber assertions pin the session id and match the full envelope:
  `assert_receive {:statifier, ^session_id, {:effect, {:done, %Effect.Done{}}}}`
  ([`test/statifier/session_test.exs:183`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L183)), with `{:halted, :done | :cancelled |
  :budget_exhausted}` (`:184`, `:467`, `:520`) and
  `{:unroutable, {:send, ^send_effect}}` (`:557`). Ordering is asserted by
  issuing the `assert_receive` calls in sequence (`:461-467`).
- Every current `interpret/2` call site is a one-element list literal built
  inline: [`test/statifier/session_test.exs:322`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L322), `:349`, `:351`, `:367`,
  `:397`, `:402`, `:435`, `:554`, `:579`. No test batches unrelated effect
  kinds into one call - a recording that has to survive a multi-effect batch
  has no existing example.
- Wall-clock handling: small `delay_ms` values (30, 40 ms; 200 ms for the
  shared-id cancel at `:392`; 1000 ms only where the timer must never fire,
  `:430`), one `Process.sleep(60)` matched to a 30 ms schedule (`:355`),
  `refute_receive ..., 20` (`:325`), and the polling helper
  `wait_for_status/3` (`:596-612`) for "wait until the drain loop settles".
- Sabotage lines name the exact mutation and its consequence, e.g.
  `# sabotage: `next/1` uses `:queue.out_r/1` (back of the queue) instead of
  `:queue.out/1` -> the assertion on dequeue order reddens`
  ([`test/statifier/session/inbox_test.exs:10-11`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session/inbox_test.exs#L10-L11)). Harness-only tests carry an
  explicit `# sabotage: n/a - ...` ([`test/statifier/session_test.exs:223-225`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L223-L225),
  [`test/statifier/session/effects_test.exs:262-263`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session/effects_test.exs#L262-L263)), per [`docs/testing.md:87-129`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/testing.md#L87-L129).
- **No existing test compares two runs.** The closest is
  [`test/statifier/session_test.exs:92-101`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L92-L101), which compares one session-driven
  snapshot against a single direct `Statifier.initialize/2` call field by
  field, and [`test/statifier/session/effects_test.exs:273`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session/effects_test.exs#L273), which compares a
  whole `plan/1` instruction list against a table fixture. The round-trip
  comparison st-dtm's acceptance criteria describes is a new shape.

## Code References

- [`lib/statifier/session.ex:181-184`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L181-L184) - `start_link/2` option split; the shape a recording option would take
- [`lib/statifier/session.ex:199-203`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L199-L203) - `send_event/2`, input 3
- [`lib/statifier/session.ex:205-234`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L205-L234) - `interpret/2` and its four-input recording `@doc` (ADR-0029)
- [`lib/statifier/session.ex:236-245`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L236-L245) - `cancel/1`, the ordered queue entry
- [`lib/statifier/session.ex:289-307`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L289-L307) - `init/1`, inputs 1 and 2, and where the resolved session id is read
- [`lib/statifier/session.ex:316-333`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L316-L333) - the drain loop and its halted-state rules
- [`lib/statifier/session.ex:363-373`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L363-L373) - the three cast clauses
- [`lib/statifier/session.ex:377-392`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L377-L392) - the fired-timer path and its "one recordable input path" comment
- [`lib/statifier/session.ex:406-417`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L406-L417) - `terminate/2` cancels live timers (spec 6.2)
- [`lib/statifier/session.ex:448-455`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L448-L455) - `perform/3`, where `Effects.plan/1` output is executed
- [`lib/statifier/session.ex:472-494`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L472-L494) - `{:enqueue_event, _}` and `{:schedule, _, _, _}` instructions; the one `make_ref/0` and `Process.send_after/3` in the library
- [`lib/statifier/session.ex:553-571`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L553-L571) - terminal configuration read off `%Effect.Done{}`
- [`lib/statifier/session/effects.ex:44-52`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L44-L52) - `plan/1` and the targetless-send re-enqueue
- [`lib/statifier/session/inbox.ex:24-56`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/inbox.ex#L24-L56) - entries, `enqueue_event/2`, `enqueue_cancel/1`, `next/1`
- [`lib/statifier/session/timers.ex:34-79`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/timers.ex#L34-L79) - `put/3`, `take/2`, `forget/2`, `refs/1`
- [`lib/statifier/machine_state.ex:293-313`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L293-L313) - the `%MachineState{}` fields
- [`lib/statifier/machine_state.ex:384-407`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L384-L407) - `new/2` and the four recordable options; the UXID call at `:386`
- [`lib/statifier/evaluator/system_variables.ex:51-60`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/evaluator/system_variables.ex#L51-L60) - `_sessionid`, `_name`, `_event`, `_ioprocessors`
- [`lib/statifier/interpreter.ex:217-219`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L217-L219), `:429-431`, `:771-773` - `initialize/2`, `handle_event/2`, `cancel/1`
- [`lib/statifier/interpreter.ex:1362-1406`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L1362-L1406) - the invoke-id counter and its purity comment
- [`lib/statifier/event.ex:44-56`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/event.ex#L44-L56) - the `%Event{}` fields; no timestamp, no id
- [`lib/statifier/effect.ex:113-148`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L113-L148) - the closed `Effect.t()` union and `trace?/1`
- [`lib/statifier/effect.ex:161-173`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L161-L173) - the `trace/3` emission gate
- [`lib/statifier/interpreter/exit_entry.ex:465`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter/exit_entry.ex#L465), [`lib/statifier/interpreter/selection.ex:128`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter/selection.ex#L128) - `MapSet.to_list/1` on history-recorded states
- [`lib/mix/statifier/adr_guard.ex:68-74`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L68-L74) - `@core_prefix` and the single-path I/O allowlist
- [`lib/mix/statifier/adr_guard.ex:93-107`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L93-L107) - the side-effect pattern, the UXID pattern, and the citation escape
- [`test/statifier/session_test.exs:12-18`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L12-L18) - `compile!/1`
- [`test/statifier/session_test.exs:92-101`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L92-L101) - the closest existing two-value comparison
- [`test/statifier/session_test.exs:125`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L125) - the `session_id: "sess_fixed"` precedent
- [`test/statifier/session_test.exs:300-409`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L300-L409) - the `interpret/2` delayed-send and cancel suites
- [`test/statifier/session_test.exs:596-612`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L596-L612) - `wait_for_status/3`

## Architecture Documentation

- **ADR-0003** (pure core with effects) is the warrant for `interpret/2`
  ("Embedders can supply their own effect interpreter") and the reason
  `lib/statifier/session.ex` is the only I/O path under `lib/statifier/`.
- **ADR-0012** makes the observability constraints binding;
  [`docs/observability.md:145-165`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/observability.md#L145-L165) is constraint 6, which now states the
  four-input tuple itself rather than deferring to the `@doc`.
- **ADR-0029** decided `interpret/2` stays public, widened the recording to
  four inputs, and filed st-dtm - including the ruling that the recorder cannot
  be a subscriber, and the explicit note that "whether it is a session option
  or a cooperating wrapper is that bead's design work, deliberately not settled
  here" ([`docs/adr/0029-session-interpret-stays-public.md:85-95`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/adr/0029-session-interpret-stays-public.md#L85-L95)). Its
  Consequences also name what would reopen it: st-dtm discovering that
  input-side recording cannot capture `interpret/2` batches without a
  session-side change the record forbids (`:117-122`). Nothing in this research
  suggests that condition is met - the batch is already a plain term arriving
  on a cast clause.
- **ADR-0008** as amended splits generated identifiers on the core boundary:
  UXID outside (the `sess_` id), pure counters inside (the `inv_` id). That
  split is why exactly one value needs recording rather than a general entropy
  log.
- **ADR-0019 / ADR-0020** fix the round budget and the round ordinal, which
  make the counters stamped on trace effects a total order two runs can be
  compared on.
- **ADR-0027** places the session in the embedder's supervision tree, which is
  why `start_link/2` and `child_spec/1` are the whole runtime surface a
  replayer has to work with.
- **ADR-0018** bars process jargon from code comments, and
  `lib/mix/statifier/adr_guard.ex` enforces it on added lines; new recorder
  comments are subject to it.

## Historical Context

- [`docs/plans/260814-st-cmq.4-session-genserver-effect-interpreter.md:234-256`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260814-st-cmq.4-session-genserver-effect-interpreter.md#L234-L256)
  is Decision 9, where `interpret/2` was shipped as "a public seam, not a test
  hook" with st-cmq.11 named as its revisit trigger; lines `:244-252` already
  state the widening this bead now implements, and `:771` calls the drain path
  "the single recordable input path".
- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md` is
  the research behind that session, covering the effect vocabulary, delayed-send
  timers, and `_name` initialization.
- st-cmq.11 (closed) recorded the decision and its outcome, including the note
  that the recorder "must attach on the input side, since the subscriber stream
  cannot distinguish injected from derived effects". st-dtm is
  `discovered-from` it.
- `docs/research/260813-st-ux0-livelock-round-trace-identity.md` and
  `docs/plans/260813-st-ux0-livelock-round-ordinal.md` are why an empty round is
  still countable and ordered, which is what makes a trace-effect stream
  comparable between two runs.
- `docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md` covers
  the invoke passes whose ids the pure counter keeps replayable.

## Related Research

- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md`
- `docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md`
- `docs/research/260813-st-ux0-livelock-round-trace-identity.md`
- `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md`

## Open Questions

No human was available while this research ran; these are recorded rather than
asked.

1. **What "with session timestamps" means, given nothing reads a clock.**
   [`docs/observability.md:154`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/observability.md#L154) promises timestamps, but `lib/statifier/` makes
   no clock call anywhere (`make_ref/0` at [`lib/statifier/session.ex:484`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L484) is
   the only non-pure call besides `Process.send_after/3`). Recording a real
   timestamp means introducing the first clock read in the library, on a path
   the ADR guard watches. An ordinal position in the serialized order is
   sufficient to reproduce *order*; only *relative timing* would need a clock,
   and the bead says replay must not re-wait delays.

2. **How replay avoids re-arming the timers it is replaying.** A re-injected
   `interpret/2` batch containing `{:send_delayed, ...}` is planned to
   `{:schedule, ...}` by the same `Effects.plan/1` a live session runs
   ([`lib/statifier/session/effects.ex:58-60`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session/effects.ex#L58-L60)), so the replayed session both
   receives the recorded firing and arms a fresh timer that fires again. The
   candidate resolutions visible in the code - a replay mode that suppresses
   `{:schedule, ...}`, a replayer that drives the pure core plus its own
   planner instead of a live session, or cancelling on injection - each have
   different consequences for how faithfully "the same code path" is exercised,
   and none is settled anywhere today.

3. **Where the recorder lives, given the gate.** A pure value threaded on
   `Session.State`, in the shape of `Inbox`/`Timers`, passes
   `Mix.Statifier.AdrGuard` untouched. Anything process-shaped or
   file-shaped under `lib/statifier/` needs an ADR citation on the offending
   lines ([`lib/mix/statifier/adr_guard.ex:74`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/adr_guard.ex#L74), `:93-107`). Whether the
   recording is ever persisted - and if so, in what format and from which
   module - is unaddressed by any existing code; there is no serialization
   layer in the repo.

4. **Whether a recording captures the resolved or the supplied session id.**
   The resolved id is available at [`lib/statifier/session.ex:300`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/session.ex#L300) regardless of
   whether the caller supplied `:session_id`. Recording the resolved value and
   replaying it as `:session_id` closes the single nondeterminism, but it means
   the recording's "initial data" is not byte-identical to the options the
   original caller passed.

5. **What equality means for "the effect stream matches".** Struct equality is
   available and meaningful given the determinism above, but the comparison has
   to fix `trace: true`/`false` identically on both runs, and decide whether
   the session-level `{:unroutable, _}` and `{:halted, _}` subscriber messages
   - which are not effects - are part of the compared stream.

6. **Whether non-core boundary crossings are recorded at all.**
   `subscribe/2`, `unsubscribe/2`, `snapshot/1`, `status/1`, and `stop/2` cross
   the boundary but do not change the core trajectory. Excluding them is the
   obvious reading of "input"; nothing states it.

7. **The multi-effect batch has no precedent.** Every existing `interpret/2`
   call site passes a single-element list
   ([`test/statifier/session_test.exs:322`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/session_test.exs#L322) and the eight beside it), so a
   recording that must preserve batch boundaries - rather than flattening
   batches into one effect log - has no existing test to model on. Whether a
   batch boundary is semantically load-bearing (it is one `perform/3` call, so
   its effects are planned and performed as a unit) is worth stating explicitly
   in the recording's shape.
