---
date: 2026-08-17T04:56:29-0600
researcher: Claude
git_commit: 102eedce9dab0536d31c632f789e29fa84efabea
branch: st-r6l9-invoke-effect-order
repository: statifier-ex
beads_issue: st-r6l9
topic: "Why effects from a mid-batch re-entry into the core reach subscribers before the tail of the original instruction list"
tags: [research, codebase, interpreter, session, observability]
status: complete
last_updated: 2026-08-17
last_updated_by: Claude
---

# Research: mid-batch re-entry and subscriber effect order

**Date**: 2026-08-17T04:56:29-0600
**Git Commit**: 102eedce9dab0536d31c632f789e29fa84efabea
**Branch**: st-r6l9-invoke-effect-order
**Bead**: st-r6l9

## Research Question

st-r6l9 observes that a subscriber of a live `Statifier.Session` can see
effects arrive in non-monotone `(macrostep, round)` order, with more than one
`Trace.MacrostepStable` inside one macrostep and with trace effects arriving
*after* `{:halted, :done}`. The bead names the ADR-0039 seam as the mechanism
and claims `Statifier.Replay` produces the monotone order the live session
does not.

This document maps the code as it stands today: the notification path, where
the seam is crossed, where `{:halted, _}` is emitted relative to it, what
`docs/observability.md` constraint 2 actually promises, which effects carry
`round`, whether the replay claim holds, and what test surface exists for
asserting delivery order.

## Summary

The delivery path is a single ordered fold. `perform/3` plans an effect list
into instructions and reduces over them; `{:notify, effect}` is the head of
every effect's own instruction list, and performing it `send/2`s the message
to every subscriber immediately ([`lib/statifier/session.ex:913-936`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L913-L936),
[`lib/statifier/session.ex:1382-1386`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1382-L1386)). Arrival order is therefore exactly the
order instructions are reduced.

Two of those instruction kinds do not merely perform an effect - they drive
the core again. `{:raise, kind, name, origin, opts}` and `{:deliver, :internal,
event, effect}` both call the private `deliver_internal/6`
([`lib/statifier/session.ex:947-955`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L947-L955), [`lib/statifier/session.ex:1200-1209`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1200-L1209)),
which calls `Statifier.Interpreter.deliver_internal/5` (the ADR-0039 seam) and
then calls `perform/3` **recursively** on the effects that call returns
([`lib/statifier/session.ex:1342-1354`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1342-L1354)). The recursive `perform/3` runs to
completion - notifying subscribers of every effect the re-entry produced -
before control returns to the outer `Enum.reduce/3`, which then continues
notifying the remaining instructions of the original list. The tail of the
original batch is delivered last, even though its counters are lower.

Three consequences follow mechanically, and all three are what the bead
reports:

1. **Non-monotone `(macrostep, round)`.** `Interpreter.deliver_internal/5`
   does **not** call `MachineState.begin_macrostep/1`
   ([`lib/statifier/interpreter.ex:490-499`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L490-L499)) - it raises onto the internal
   queue and folds `main_event_loop/1`. The re-entry therefore keeps the same
   `macrostep` and continues advancing `round`, so its effects carry *higher*
   rounds than the outer batch's unsent tail.
2. **More than one `Trace.MacrostepStable` per macrostep.** That trace is
   emitted by `terminal_effects/2` on every quiescent fold
   ([`lib/statifier/interpreter.ex:1005-1011`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L1005-L1011)). The outer `handle_event/2` fold
   emits one, and each re-entry's own `main_event_loop/1` fold emits another,
   inside the same `macrostep`. They differ in `round`, so `(macrostep, round)`
   is not literally duplicated, but a consumer keying on `macrostep` alone sees
   a duplicate, and the second one arrives before the first.
3. **Trace effects after `{:halted, :done}`.** `{:halt, reason}` is planned by
   `Statifier.Session.Effects.plan_one/2` as the second instruction of a
   `{:done, _}` effect ([`lib/statifier/session/effects.ex:141-143`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session/effects.ex#L141-L143)), and
   `perform_instruction({:halt, reason}, ...)` calls `notify(state, {:halted,
   reason})` at that position ([`lib/statifier/session.ex:1053-1060`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1053-L1060)). When the
   run terminates *inside* a re-entry, `{:halted, :done}` is delivered inside
   the nested `perform/3`, and the outer fold then delivers the rest of the
   original list afterwards. Nothing stops the outer fold: `halted` is a
   `%State{}` field checked at `handle_continue(:drain, _)`
   ([`lib/statifier/session.ex:641-684`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L641-L684)), not inside `perform/3`.

`Statifier.Replay` does not have this shape, and the bead's claim holds - see
"Replay" below. Only trace payloads carry `round`; every core effect except
`BudgetExhausted` carries `macrostep`/`microstep` only, so a subscriber cannot
sort the whole stream on `(macrostep, round)` today.

## Detailed Findings

### The notification path

- `perform/3` ([`lib/statifier/session.ex:912-919`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L912-L919)) is the only entry into
  effect performance:

  ```elixir
  effects
  |> Effects.plan(state.session_id)
  |> Enum.reduce(state, &perform_instruction(&1, &2, halt_override))
  ```

- `Statifier.Session.Effects.plan/2` gives every effect a `{:notify, effect}`
  head, then zero or more performing instructions
  ([`lib/statifier/session/effects.ex:112-151`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session/effects.ex#L112-L151)). The moduledoc states this
  outright at [`lib/statifier/session/effects.ex:8`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session/effects.ex#L8).
- `perform_instruction({:notify, effect}, ...)`
  ([`lib/statifier/session.ex:926-936`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L926-L936)) calls `notify/2` and then
  `Telemetry.effect/3`. `notify/2` ([`lib/statifier/session.ex:1382-1386`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1382-L1386)) is
  an unconditional `send/2` per subscriber - no buffering, no reordering, no
  batching. Subscriber arrival order is fold order.
- `perform/3` has four call sites, three of them top-level drives and one of
  them the re-entry:
  - `handle_continue({:initialize, ...}, _)` ([`lib/statifier/session.ex:617-631`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L617-L631))
  - `handle_cast({:interpret, effects}, _)` ([`lib/statifier/session.ex:739-743`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L739-L743))
  - `drain_cancel/1` and `drain_event/2` ([`lib/statifier/session.ex:830-857`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L830-L857))
  - `deliver_internal/6` ([`lib/statifier/session.ex:1342-1354`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1342-L1354)) - the nested one

### The ADR-0039 seam, and where it is crossed mid-batch

ADR-0039 (`docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`)
makes `Statifier.Interpreter.deliver_internal/5` the one door the session uses
to write the machine's internal queue. Its consequences section widens it
beyond error paths: "The same seam is the delivery path for `<send
target="#_internal">`, not only for the two spec-6.2.4 failures"
([`docs/adr/0039-session-detected-send-failures-re-enter-the-core.md:89-94`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/adr/0039-session-detected-send-failures-re-enter-the-core.md#L89-L94)).
That widening is what makes the reordering reachable on a fully successful
run, as the bead's 2026-08-16 note reports.

The session-side crossings, all reached from inside `perform/3`'s fold:

- `perform_instruction({:raise, kind, name, origin, opts}, ...)` -
  [`lib/statifier/session.ex:947-949`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L947-L949)
- `perform_instruction({:deliver, route, event, effect}, ...)` ->
  `deliver/5` -> `deliver(:internal, ...)` - [`lib/statifier/session.ex:953-955`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L953-L955),
  [`lib/statifier/session.ex:1200-1209`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1200-L1209)
- `communication_error/4` (unreachable `<send>` target) -
  [`lib/statifier/session.ex:1318-1327`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1318-L1327)
- `invoke_error/4` (a failed `<invoke>`: `Source.resolve/2` or
  `Statifier.start_session/2` failed) - [`lib/statifier/session.ex:1165-1174`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1165-L1174),
  reached from `perform_instruction({:start_child, ...}, ...)` at
  [`lib/statifier/session.ex:997-1002`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L997-L1002)

The invoke-failure path the bead was originally filed against is the fourth of
these; the internal-send path is the first two. All four converge on the same
`deliver_internal/6`.

`deliver_internal/6` itself ([`lib/statifier/session.ex:1342-1354`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1342-L1354)) records the
call for replay, opens its own `in_macrostep/4` span, calls
`Interpreter.deliver_internal/5`, and calls `perform/3` on the result. The
recursion is unbounded in principle: an effect produced by the re-entry can
itself be a `{:raise, ...}`.

### Counters: why the re-entry's rounds are higher

- `MachineState.begin_macrostep/1` is the only writer of `macrostep` and
  resets `microstep`/`round` ([`lib/statifier/machine_state.ex:679-681`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine_state.ex#L679-L681),
  contract at [`lib/statifier/machine_state.ex:221-264`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine_state.ex#L221-L264)). Its only two callers
  are `Interpreter.initialize/2` ([`lib/statifier/interpreter.ex:223`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L223)) and
  `Interpreter.handle_event/2` ([`lib/statifier/interpreter.ex:434`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L434)).
- `Interpreter.deliver_internal/5` ([`lib/statifier/interpreter.ex:490-499`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L490-L499))
  calls neither - it raises onto the internal queue and calls
  `main_event_loop/1` directly.
- `MachineState.begin_round/1` ([`lib/statifier/machine_state.ex:703-705`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine_state.ex#L703-L705)) is
  called at the head of `Interpreter.microstep/1`
  ([`lib/statifier/interpreter.ex:932-936`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L932-L936)), including the terminal clause.

So a re-entry continues the enclosing macrostep and pushes `round` forward
from wherever the outer fold left it. The bead's captured trace matches
exactly: the outer batch's tail carries `m=2 r=0`/`r=1`, and the re-entry that
preempted it carries `m=2 r=2`/`r=3`.

### `in_macrostep/*` and the telemetry spans (ADR-0040)

`in_macrostep/4` ([`lib/statifier/session.ex:868-903`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L868-L903)) wraps each core drive in
a `[:statifier, :session, :macrostep, :start]`/`:stop` span pair, per ADR-0040
decisions 2 and 3 ([`docs/adr/0040-session-telemetry-event-contract.md:250-282`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/adr/0040-session-telemetry-event-contract.md#L250-L282)).
It is called from `drain_cancel/1` (`:cancel`), `drain_event/2` (`:event`), and
`deliver_internal/6` (`:internal`).

The nesting is already documented in the code. The comment at
[`lib/statifier/session.ex:875-884`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L875-L884) says that `drive.()` "can itself call
`deliver_internal/6`, which opens and closes its own nested `in_macrostep/4`
span before this (outer) one closes", and keeps `start_time` in a closure
binding so the inner span does not clobber the outer one's start time. So the
telemetry layer already models the re-entry as a *nested span*, while the
`{:effect, _}` subscriber stream models it as a flat sequence - the two views
disagree about the same run.

Note also that the `:internal` trigger's span opens with `event: nil`
([`lib/statifier/session.ex:1345`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1345)), so a telemetry consumer cannot name the
event that caused the nested span from the span metadata alone.

### Where `{:halted, _}` is emitted, and what consumers are told

- Planned by `Effects.plan_one/2` for `{:done, _}` and `{:budget_exhausted,
  _}` ([`lib/statifier/session/effects.ex:141-147`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session/effects.ex#L141-L147)); `Statifier.Session`'s
  `drain_cancel/1` supplies `halt_override: :cancelled`
  ([`lib/statifier/session.ex:831-844`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L831-L844)).
- Performed at [`lib/statifier/session.ex:1053-1060`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1053-L1060): set `state.halted`, run
  `return_done_event/2`, `notify(state, {:halted, reason})`,
  `Telemetry.halt/3`.
- The documented promise is in the session moduledoc, at
  [`lib/statifier/session.ex:74-76`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L74-L76): "`{:halted, :done | :cancelled |
  :budget_exhausted}` - one lifecycle message, **following the effects that
  caused it**." The promise is about the causing effects only; nothing in the
  moduledoc says it is the last message a subscriber will see, and nothing in
  `perform/3` makes it so. `docs/observability.md` never mentions `{:halted,
  _}` at all.
- `state.halted` is consulted in `handle_continue(:drain, _)`
  ([`lib/statifier/session.ex:650-652`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L650-L652)) to stop draining queued events, and in
  `macrostep_outcome/1` ([`lib/statifier/session.ex:905-908`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L905-L908)). It is not
  consulted anywhere inside `perform/3`, which is why the outer fold keeps
  notifying after a nested halt.

### What `docs/observability.md` constraint 2 promises

Constraint 2's ordering line is [`docs/observability.md:85-86`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/observability.md#L85-L86):

> Trace effects are ordinary members of the effect list - same ordering
> guarantees, same delivery path. No side channel.

Read literally, this is a statement about trace effects *relative to other
effects in the same list*, and about the delivery path being shared. It holds
today: a trace effect and a core effect in one list are notified in list
order, through the same `notify/2`. It does not say anything about the
relationship between two different lists, which is exactly the relationship a
re-entry creates. The document's counters constraint is stronger in tone -
constraint 4 at [`docs/observability.md:125-127`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/observability.md#L125-L127) says "`(macrostep, round)` is
the ordering key for any timeline UI or log merge" - but stops short of
promising that the delivery order and that key agree.

Constraint 6 ([`docs/observability.md:147-171`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/observability.md#L147-L171)) names `Statifier.Session` as
the observation boundary and the `{:statifier, session_id, {:effect, effect}}`
message as its shape; it makes no ordering claim of its own.

### Which effects carry `round` and `macrostep`

Every trace payload carries all three counters; every core effect except
`BudgetExhausted` carries `macrostep`/`microstep` only. `Statifier.Effect`'s
moduledoc states the rule at [`lib/statifier/effect.ex:52-63`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect.ex#L52-L63).

| Payload | File | macrostep | microstep | round |
|---|---|---|---|---|
| `Effect.Send` | [`lib/statifier/effect/send.ex:48`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/send.ex#L48) | yes | yes | no |
| `Effect.SendDelayed` | [`lib/statifier/effect/send_delayed.ex:25`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/send_delayed.ex#L25) | yes | yes | no |
| `Effect.Cancel` | [`lib/statifier/effect/cancel.ex:20`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/cancel.ex#L20) | yes | yes | no |
| `Effect.Invoke` | [`lib/statifier/effect/invoke.ex:46`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/invoke.ex#L46) | yes | yes | no |
| `Effect.CancelInvoke` | [`lib/statifier/effect/cancel_invoke.ex:36`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/cancel_invoke.ex#L36) | yes | yes | no |
| `Effect.Autoforward` | [`lib/statifier/effect/autoforward.ex:41`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/autoforward.ex#L41) | yes | yes | no |
| `Effect.Done` | [`lib/statifier/effect/done.ex:21`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/done.ex#L21) | yes | yes | no |
| `Effect.Log` | [`lib/statifier/effect/log.ex:23`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/log.ex#L23) | yes | yes | no |
| `Effect.DatamodelChange` | [`lib/statifier/effect/datamodel_change.ex:36`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/datamodel_change.ex#L36) | yes | yes | no |
| `Effect.BudgetExhausted` | [`lib/statifier/effect/budget_exhausted.ex:30`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/budget_exhausted.ex#L30) | yes | yes | **yes** |
| all nine `Effect.Trace.*` | `lib/statifier/effect/trace/*.ex` | yes | yes | yes |

`BudgetExhausted` is the documented exception - its `round` is the spent
budget at exhaustion, per ADR-0020
([`lib/statifier/effect/budget_exhausted.ex:18-23`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect/budget_exhausted.ex#L18-L23)).

Trace payloads are stamped in each module's own `new/2`, called through the
`Effect.trace/3` macro ([`lib/statifier/effect.ex:167-177`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect.ex#L167-L177)); core effects are
built as struct literals at their emission sites, each reading the counters
off the `machine_state` in scope. `{:halted, reason}` and `{:unroutable,
effect}` are envelopes, not payloads, and carry no counters of their own.

This is the concrete form of the bead's "sorting by (macrostep, round) is only
possible once every effect carries round": a subscriber can sort the trace
sub-stream on `(macrostep, round)` today, but cannot place a `Effect.Send` or
`Effect.Invoke` within it - `macrostep`/`microstep` alone does not order two
payloads from different rounds of the same macrostep.

### Replay - the bead's claim verified

The claim holds. `Statifier.Replay` cannot exhibit the reordering, by
construction:

- `Replay.perform_instruction({:raise, ...}, ...)` is a **no-op**
  ([`lib/statifier/replay.ex:375-377`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L375-L377)), and so is `{:deliver, _route, ...}` for
  every route except a self-addressed `{:session, sid}`
  ([`lib/statifier/replay.ex:384-397`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L384-L397)).
- The only call site of `Interpreter.deliver_internal/5` in that module is
  `apply_entry({:internal, kind, name, origin, opts}, state)`
  ([`lib/statifier/replay.ex:238-240`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L238-L240), [`lib/statifier/replay.ex:332-340`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L332-L340)),
  which walks the recording's **flat** entry list.
- `Statifier.Session` records the internal delivery at
  [`lib/statifier/session.ex:1343`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1343) - `Recording.put_internal/5`, called before
  `in_macrostep/4` opens. The recording is a flat, ordinal list, so the
  `{:internal, ...}` entry lands *after* the entry that triggered it, not
  inside it - [`lib/statifier/replay.ex:72-92`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L72-L92) states this as the module's own
  design ("interleaved with, not nested inside, the entry that triggered it").

The result: replay appends the whole outer batch to `stream` first
([`lib/statifier/replay.ex:345-352`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L345-L352), `append/2` at
[`lib/statifier/replay.ex:468-469`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L468-L469)), then the re-entry's effects when it reaches
the `{:internal, ...}` entry. Since the re-entry carries the higher rounds,
replay's stream is monotone on the same run whose live stream is not.
`{:halted, reason}` lands last in replay for the same reason.

The mechanical detector the bead describes therefore already has a harness:
`round_trip/3` in [`test/statifier/replay_round_trip_test.exs:103-119`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L103-L119) asserts
`result.stream == stream` - exact ordered list equality between the replayed
stream and the drained live-subscriber stream. No existing round-trip test
drives a chart that crosses the seam, which is why it is green today. The two
existing tests that *do* cross it -
[`test/statifier/replay_test.exs:370-386`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_test.exs#L370-L386) (a `#_internal` send plus a failed
`#_scxml_foo` send) and [`test/statifier/replay_test.exs:420-437`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_test.exs#L420-L437) (a `#_parent`
send with no parent) - start their sessions without `subscribers:` and assert
only on the final configuration, never on stream order.

### Test surface for delivery order

- **Live subscriber ordering, sequential `assert_receive`**:
  [`test/statifier/session_test.exs:176-188`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/session_test.exs#L176-L188) (done then halted) and
  [`test/statifier/session_test.exs:457-473`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/session_test.exs#L457-L473) (four messages in exit order,
  under `cancel/1`).
- **Exact ordered stream equality**:
  [`test/statifier/replay_round_trip_test.exs:262-268`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L262-L268) compares a non-trace
  projection of the live stream against a literal three-element list;
  [`test/statifier/replay_test.exs:324-341`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_test.exs#L324-L341) asserts `result.stream ==
  [{:effect, log_one}, {:effect, log_two}]`.
- **The drain helper**: `drain_stream/2`
  ([`test/statifier/replay_round_trip_test.exs:91-97`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L91-L97)) receives every
  `{:statifier, ^session_id, message}` until a 100ms quiet window, strips the
  envelope, and preserves arrival order. It is private to that file, not
  shared support code.
- **The round-trip driver**: `round_trip/3`
  ([`test/statifier/replay_round_trip_test.exs:103-119`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L103-L119)) starts a session with
  `record: true, trace: true, subscribers: [self()]`, runs a caller-supplied
  drive function, drains the stream, replays, and asserts both
  `result.stream == stream` and `result.machine_state == snapshot`.
- **`wait_for_status/2,3`**: a poll-until-predicate helper, defined
  independently in `test/statifier/session_test.exs`,
  `test/statifier/replay_test.exs`, and
  [`test/statifier/replay_round_trip_test.exs:69-82`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L69-L82). Not shared.
- **Corpus harness**: `Statifier.Case`'s `drive_through_session/3`
  ([`test/support/case.ex:173-190`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/support/case.ex#L173-L190)), `poll_until_settled/4`
  ([`test/support/case.ex:237-260`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/support/case.ex#L237-L260)), and `drain_done_effect/1`
  ([`test/support/case.ex:284-294`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/support/case.ex#L284-L294)). It subscribes with `subscribers: [self()]`
  but polls status rather than reading mailbox order, and it is used only by
  the SCION/W3C corpus.

There is no existing helper that asserts monotonicity of `(macrostep, round)`
over a captured stream, and no existing test that starts a subscriber on a
chart that crosses the ADR-0039 seam.

## Code References

- [`lib/statifier/session.ex:912-919`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L912-L919) - `perform/3`: plan, then `Enum.reduce/3`
- [`lib/statifier/session.ex:926-936`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L926-L936) - `{:notify, effect}` -> `notify/2` +
  `Telemetry.effect/3`
- [`lib/statifier/session.ex:947-955`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L947-L955) - the two instruction kinds that re-enter
  the core mid-fold
- [`lib/statifier/session.ex:997-1002`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L997-L1002) - `{:start_child, ...}` -> `invoke_error/4`
  on failure
- [`lib/statifier/session.ex:1053-1060`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1053-L1060) - `{:halt, reason}` -> `notify(state,
  {:halted, reason})`
- [`lib/statifier/session.ex:1200-1209`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1200-L1209) - `deliver(:internal, ...)`
- [`lib/statifier/session.ex:1318-1327`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1318-L1327) - `communication_error/4`
- [`lib/statifier/session.ex:1342-1354`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1342-L1354) - `deliver_internal/6`: record, span,
  seam, recursive `perform/3`
- [`lib/statifier/session.ex:1382-1386`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1382-L1386) - `notify/2`, the single `send/2` fan-out
- [`lib/statifier/session.ex:868-903`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L868-L903) - `in_macrostep/4` and its nesting comment
- [`lib/statifier/session.ex:641-684`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L641-L684) - `handle_continue(:drain, _)`, the only
  `state.halted` gate on further work
- [`lib/statifier/session/effects.ex:112-151`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session/effects.ex#L112-L151) - `plan/2` and `plan_one/2`
- [`lib/statifier/interpreter.ex:490-499`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L490-L499) - `deliver_internal/5`: no
  `begin_macrostep/1`
- [`lib/statifier/interpreter.ex:433-453`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L433-L453) - `handle_event/2`: `begin_macrostep/1`
- [`lib/statifier/interpreter.ex:932-936`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L932-L936) - `microstep/1` -> `begin_round/1`
- [`lib/statifier/interpreter.ex:1005-1011`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L1005-L1011) - `terminal_effects/2` emits
  `Trace.MacrostepStable` on every quiescent fold
- [`lib/statifier/machine_state.ex:221-264`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine_state.ex#L221-L264) - the counter contract
- [`lib/statifier/machine_state.ex:679-705`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine_state.ex#L679-L705) - `begin_macrostep/1`,
  `begin_microstep/1`, `begin_round/1`
- [`lib/statifier/replay.ex:72-92`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L72-L92) - "defer to the recorded `{:internal, ...}`
  entry"
- [`lib/statifier/replay.ex:238-240`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L238-L240) - `apply_entry({:internal, ...}, _)`
- [`lib/statifier/replay.ex:375-397`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/replay.ex#L375-L397) - the `{:raise, ...}`/`{:deliver, ...}`
  no-ops
- [`lib/statifier/effect.ex:52-63`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect.ex#L52-L63) - "No core effect carries `round`"
- [`test/statifier/replay_round_trip_test.exs:91-119`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_round_trip_test.exs#L91-L119) - `drain_stream/2` and
  `round_trip/3`
- [`test/statifier/replay_test.exs:370-386`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/test/statifier/replay_test.exs#L370-L386) - a live run that crosses the seam,
  asserting configuration only

## Architecture Documentation

- **ADR-0003** puts the pure core on one side of the boundary and the effect
  interpreter on the other. The re-entry exists because routing lives on the
  interpreter side and the internal queue lives on the core side.
- **ADR-0039** names `Interpreter.deliver_internal/5` as the single door back
  in, and its consequences widen that door to ordinary
  `<send target="#_internal">` traffic, not just failures
  ([`docs/adr/0039-session-detected-send-failures-re-enter-the-core.md:89-94`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/docs/adr/0039-session-detected-send-failures-re-enter-the-core.md#L89-L94)).
- **ADR-0040** models the same re-entry as a *nested* macrostep span, and
  [`lib/statifier/session.ex:875-884`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L875-L884) explains the closure that keeps nested
  span durations correct. The span view and the flat subscriber-stream view of
  one run are structured differently.
- **ADR-0034** decided that replay re-drives the core rather than a live
  session, and that the recording is a flat ordinal entry list. That decision
  is the direct cause of replay's monotone stream.
- **ADR-0029** made `deliver_internal/5` a recordable session-side input; the
  `{:internal, ...}` entry it produces is what replay walks.
- **ADR-0020** governs the counters: `round` advances on every round including
  those that run no microstep, and `begin_macrostep/1` resets both child
  counters.
- **ADR-0002** requires an inline mechanical-reason comment for every
  deviation from Appendix D; `Interpreter.deliver_internal/5`'s `@doc`
  ([`lib/statifier/interpreter.ex:456-482`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/interpreter.ex#L456-L482)) carries that citation for the
  re-entry itself.

## Historical Context

- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md` -
  the research behind the `Statifier.Session` effect interpreter and its
  subscriber fan-out.
- `docs/research/260815-st-cmq.5-external-send-targets-and-scxml-event-io-processor.md`
  - the send-routing work that produced the ADR-0039 crossings.
- `docs/research/260815-st-cmq.7-invoke-scxml-child-sessions.md` and
  `docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md` -
  the `<invoke>` work whose failure path the bead was originally filed
  against.
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  recorder's placement on the input path, which is why the recording is flat.
- `docs/research/260816-st-cmq.1-session-telemetry-effect-trace-streams.md` -
  the nine questions ADR-0040 settled, including the span shape.
- `docs/research/260813-st-ux0-livelock-round-trace-identity.md` - the round
  counter's identity semantics.
- Upstream, the bead cites `docs/research/260816-sui-t36.1-trace-coverage-spike.md`
  in statifier-ui (GAP 4). That repository was not read for this document.

## Open Questions

1. **Is a nested re-entry (a re-entry whose own effects raise again)
   reachable from a document today?** `deliver_internal/6` recurses through
   `perform/3` with no depth limit, and nothing in the code forbids it, but no
   chart exercising it was found. If reachable, the delivery order interleaves
   at more than two levels.
2. **What is the intended contract?** Two readings of a fix are consistent
   with today's documents, and choosing between them is a design decision this
   pass deliberately does not make: (a) delivery order should match
   `(macrostep, round)`, meaning the re-entry's effects are buffered until the
   outer fold drains, or (b) delivery order should stay causal/nested and the
   consumer contract should be restated so `{:halted, _}` is not end-of-stream
   and `MacrostepStable` is not once-per-macrostep. ADR-0040's nested spans
   lean toward (b); `docs/observability.md` constraint 4's "ordering key"
   language leans toward (a).
3. **Does `{:halted, _}` have a stated end-of-stream promise anywhere outside
   [`lib/statifier/session.ex:74-76`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L74-L76)?** None was found in `docs/`, and the
   consumer that broke (statifier-ui) inferred it. Whether that inference is
   one this project intends to honor is unsettled here.
4. **Does the `:internal` macrostep span's `event: nil`
   ([`lib/statifier/session.ex:1345`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1345)) matter to a telemetry consumer trying to
   correlate a nested span with the effect that opened it?** Not investigated.
5. **Does the same reordering reach the `:cancelled` and `:budget_exhausted`
   halts?** `halt_override: :cancelled` is threaded through
   `deliver_internal/6` ([`lib/statifier/session.ex:1348`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/session.ex#L1348)), so structurally yes,
   but no captured trace of it was found.
6. **Is `Effect.Send`/`Effect.SendDelayed`/`Effect.Cancel`'s "not yet
   produced" note in [`lib/statifier/effect.ex:26-28`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/effect.ex#L26-L28) stale?** The bead's own
   capture shows `Effect.Send` in a live stream, and
   [`lib/statifier/machine/content/send.ex:347-366`](https://github.com/riddler/statifier-ex/blob/102eedce9dab0536d31c632f789e29fa84efabea/lib/statifier/machine/content/send.ex#L347-L366) builds both. The vocabulary
   table appears not to have been updated; not chased further here.
