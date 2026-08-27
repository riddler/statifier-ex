# Durable Timers: Delayed Sends That Outlive the Process

This is a guide for a host application author who wants a `<send delay="...">`
to survive past the process that scheduled it - a node restart, a deploy, a
crash - by taking over its scheduling from `Statifier.Session`. It does not
re-explain the interpreter's architecture; see `docs/architecture.md` for
that. It shows you the two effects to consume, the two ways to consume them,
and the contract you take on when you do.

## Why you would want this

`Statifier.Session` schedules a delayed send with `Process.send_after/3`
(in `Statifier.Session`'s `{:schedule, ...}` instruction clause of
`perform_instruction/3`, the library's one call to it). That timer
lives in the BEAM's own timer wheel, tied to the session process: it dies
with the node the process was running on. For delays measured in seconds
that is rarely a problem. For a follow-up, an escalation, or a timeout
measured in hours or days, it is - a deploy or a crash between scheduling and
firing silently drops the send.

`docs/adr/0003-pure-core-with-effects.md`'s Consequences sanctioned exactly
this substitution the day the effect boundary was decided: "Embedders can
supply their own effect interpreter (e.g. queue delayed sends into Oban
instead of process timers)." That sentence named the destination; this guide
and `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md` are it.
ADR-0054 is the contract this guide teaches - read it once, alongside this
document, if you want the reasoning behind a rule rather than only the rule.

## What you consume

Two members of the public effect vocabulary (`lib/statifier/effect.ex`)
carry the whole seam:

```elixir
%Statifier.Effect.SendDelayed{
  event: String.t(),
  target: String.t() | nil,
  type: String.t() | nil,
  data: term(),
  send_id: String.t() | nil,
  delay_ms: non_neg_integer(),
  c_index: non_neg_integer() | nil,
  owner: Statifier.Machine.Content.owner() | nil,
  macrostep: non_neg_integer(),
  microstep: non_neg_integer(),
  round: non_neg_integer(),
  ordinal: pos_integer(),
  id_from_author?: boolean(),
  caller_context: term()
}
```

(`Statifier.Effect.SendDelayed`, `lib/statifier/effect/send_delayed.ex`).
`delay_ms` is **relative**,
not an absolute deadline - it is milliseconds from the moment the send was
scheduled, so your store needs to compute (or record) the fire time itself.

```elixir
%Statifier.Effect.Cancel{
  send_id: String.t(),
  c_index: non_neg_integer() | nil,
  owner: Statifier.Machine.Content.owner() | nil,
  macrostep: non_neg_integer(),
  microstep: non_neg_integer(),
  round: non_neg_integer(),
  ordinal: pos_integer(),
  caller_context: term()
}
```

(`Statifier.Effect.Cancel`, `lib/statifier/effect/cancel.ex`). `ordinal` on
both structs is a
per-execution sequence number off `machine_state.timer_counter`, decided by
`docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md` - it is
what keeps two executions of the same `<send delay>` or `<cancel>` node
(a `<foreach>` body iterating) distinct in your store's dedup key below.

`caller_context` on both structs is ADR-0063's opaque host slot: whatever
correlation term the current macrostep's triggering external event carried
(an OTel span context, a request id), copied onto the effect at
construction and never read by the library. Carry it as **row data beside
the key components, never a key component itself** (ADR-0063 decision 6:
an opaque host term is not comparable across hosts, not bounded, and not
replay-relevant to identity), and read it back at firing or cancellation
time so the firing site can link to the trace that scheduled the timer.
`nil` means no context was attached.

These are the **only** two things a durable-timer host reads. The instruction
vocabulary - `{:schedule, ...}` and `{:cancel_timers, ...}`
(`Statifier.Session.Effects`'s `@type instruction`) - is not yours to read, even
though the two names look like an obvious match for "schedule a timer" and
"cancel a timer." `docs/extending.md:58-59` already states the general rule:
"The instruction vocabulary a planning callback returns is opaque outside the
library." ADR-0054 decision 1 applies that same rule to the timer case by
name, because `{:schedule, ...}` and `{:cancel_timers, ...}` are how
`Statifier.Session` itself performs `Process.send_after/3` and
`Process.cancel_timer/1` internally - if you have seen those atoms in a stack
trace or a `:telemetry` payload, resist the pull to intercept them. Consume
the effect, not the instruction.

## Route A: a live session

If you are running `Statifier.Session` processes, subscribe to one and
pattern-match the two effects out of the stream. Before you enqueue a
`SendDelayed` effect into your store, check its `target`: **only a `nil`
target is yours to schedule.** `plan_send_delayed/3`
(`lib/statifier/session/effects.ex`) resolves `send.target` into a
route - `:self` for `nil`, `:internal` for `#_internal`, `:parent` for
`#_parent`, `{:session, id}` for `#_scxml_<id>`, `{:invoke, id}` for any other
`#_`-prefixed target - and that resolved route travels on the opaque
`{:schedule, ...}` instruction (ADR-0054 decision 1 forbids reading it), never
on the `%SendDelayed{}` effect itself. `target` on the struct you actually
receive is only ever the raw string the author wrote, or `nil`; there is no
string spelling that means "self" the way `nil` does. `deliver_fired/4`
(`lib/statifier/session.ex`) special-cases `:self` alone, re-enqueuing
onto the session's own inbox; every other route goes through `deliver/5`, and
the event it delivers is built inside the session, not by you -
`delivered_event/2` (`effects.ex`) stamps `origin`/`origintype`/`sendid`
for the ordinary case, and `#_internal` uses a different carrier entirely,
`internal_event/1` (`effects.ex`), whose delivery re-raises through
`Statifier.Interpreter.deliver_internal/5`. There is no public door from
outside the session that reconstructs any of this for `#_parent`,
`#_invokeid`, `#_internal`, or an external session id. So: schedule a
`%SendDelayed{}` whose `target` is `nil`, and **ignore** (leave to the
library) any other target - the effect stream is observational, so ignoring
one costs nothing and the session's own `Process.send_after/3` still fires it.
This is a deliberate limit, decided rather than pending:
`docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md` makes it
permanent for `#_parent`, `#_invokeid`, and `#_internal` (those routes name
the sending session's live process bookkeeping, which a durable timer by
definition outlives) and defers the external-session route behind a named
trigger. If your document wants a durable delayed send to reach its parent
or an invoked child, restructure it: delay a send to yourself, and let the
transition it triggers do an immediate `<send target="#_parent">` from the
live session.

`{:halted, reason}` is end-of-stream on this subscriber channel (ADR-0044
decision 2, `Statifier.Session`'s "One subscriber stream" moduledoc
section): once you see it, no further
effects - cleanup or otherwise - arrive for that session id. Do not sit
waiting for one after a halt.

```elixir
@spec subscribe(server :: Statifier.Session.server(), pid :: pid()) :: :ok
def subscribe(server, pid)

@spec subscribe(
        server :: Statifier.Session.server(),
        pid :: pid(),
        opts :: Statifier.Session.subscribe_opts()
      ) :: :ok | {:ok, Statifier.Session.Recording.t()} | {:error, :not_recorded}
def subscribe(server, pid, opts)
```

(`Statifier.Session.subscribe/2` and `subscribe/3`). Every effect the core
produces is planned to a `{:notify, effect}` at its original fold position,
so the subscriber stream is the complete, ordered effect list - you do not
need a second channel to see `SendDelayed` and `Cancel` alongside everything
else. A subscriber process receives `{:statifier, session_id, {:effect,
effect}}` messages; here is a minimal one that enqueues and cancels against a
host store:

```elixir
defmodule MyApp.TimerSubscriber do
  use GenServer

  alias Statifier.Effect.{Cancel, SendDelayed}

  def start_link(session_server, session_scope) do
    GenServer.start_link(__MODULE__, {session_server, session_scope})
  end

  @impl GenServer
  def init({session_server, session_scope}) do
    :ok = Statifier.Session.subscribe(session_server, self())
    {:ok, %{session_server: session_server, session_scope: session_scope}}
  end

  @impl GenServer
  def handle_info(
        {:statifier, _session_id, {:effect, {:send_delayed, %SendDelayed{target: nil} = eff}}},
        state
      ) do
    MyApp.TimerStore.enqueue(state.session_scope, eff)
    {:noreply, state}
  end

  # Any other target's route is resolved inside the session and rides the
  # opaque `{:schedule, ...}` instruction - not on this effect, and not
  # redeliverable from outside. Leave it to the library.
  def handle_info(
        {:statifier, _session_id, {:effect, {:send_delayed, %SendDelayed{}}}},
        state
      ) do
    {:noreply, state}
  end

  def handle_info({:statifier, _session_id, {:effect, {:cancel, %Cancel{} = eff}}}, state) do
    MyApp.TimerStore.cancel(state.session_scope, eff.send_id)
    {:noreply, state}
  end

  def handle_info({:statifier, _session_id, _other}, state), do: {:noreply, state}
end
```

When your durable scheduler fires a job, feed the event back in through
`Statifier.Session.send_event/2`:

```elixir
@spec send_event(server :: Statifier.Session.server(), event :: Statifier.Event.t() | String.t()) ::
        :ok
def send_event(server, event)
```

(`Statifier.Session.send_event/2`). This is the same door a fired
in-process timer rejoins through - `deliver_fired/4`
(`lib/statifier/session.ex`) re-enqueues onto the session's own
inbox "exactly as `send_event/2` does" - so your external scheduler is not
inventing a second re-entry path, it is rejoining the one that already
exists. Note that `send_event/2`, like every write door on
`Statifier.Session`, is a `GenServer.cast` - there is no synchronous variant.
Do not block your job worker waiting for a reply; the event is queued behind
whatever else is already waiting and processed in that order.

## Route B: a process-less host

If you are not running `Statifier.Session` at all - driving
`Statifier.Interpreter` directly against a persisted `%MachineState{}` - you
read the same two effects off the `[effect]` half of the interpreter's
return instead of subscribing to anything. `docs/extending.md:44-50`
describes the same audience for `<invoke>` handlers: "This is what lets a
durable host that drives `Statifier.Interpreter` directly, with no
`Statifier.Session` process at all, plan invocations the same way
`Statifier.Session` does." The same holds for delayed sends - `SendDelayed`
and `Cancel` effects appear in the returned list exactly as they would in a
live session's subscriber stream, in the same order.

The fired event goes in as the input to your host's *next* drive, not
through any function call - there is no running process to call into.

Persisting the position between drives is your responsibility, but the
format is not: `Statifier.Position.to_binary/1` writes a `%MachineState{}`
to a version-stamped, identity-checked blob, and
`Statifier.Position.from_binary/2` reads it back against the compiled
`Machine`, refusing with a typed error on a format-version or
chart-identity mismatch (ADR-0052, ADR-0060). Two fields come back `nil`
on purpose - `routes` and `invoke_types` are per-driver snapshots, not
durable position state (ADR-0064) - so re-stamp them before the next
drive. `docs/persistence.md` is the full guide: the identity checks, the
migration stories, and the rehydration recipe for a host driving the
interpreter directly. Do not invent a format of your own.

## Keying your store

ADR-0054 decision 3 corrects a natural assumption: a timer is **not**
uniquely identified by `send_id` alone, and there are two different keys in
play, not one.

| Purpose | Key | Why |
|---|---|---|
| Cancellation | `{session scope, send_id}` | May legitimately match more than one stored row. `Statifier.Session.Timers.put/3` appends per `send_id` in scheduling order and `take/2` pops every ref under an id, because spec 6.3 says a cancel with a given sendid cancels them all. An author-written `id` is reused verbatim and never advances `send_counter` (`generate_send_id/2` in `lib/statifier/machine/content/send.ex`), so one `<send id="x" delay="...">` executed twice produces two live timers under one `send_id`. A cancel that matches nothing is a no-op, not an error - mirror `take/2`'s `{[], timers}`. |
| Deduplication (at-least-once) | `{session scope, send_id, macrostep, microstep, round, c_index, owner, ordinal}` | Read off the stored `%SendDelayed{}` itself. The counters/positions are stamped as of scheduling, not firing (`Statifier.Effect.SendDelayed`'s moduledoc, ADR-0046), `ordinal` is a per-execution sequence off `machine_state.timer_counter` (ADR-0059), and every component is deterministic - no clock, no CSPRNG, no pid. Re-executing the same drive after a crash produces a byte-identical key, so your store's dedup check is sound. |

`session scope` is `ctx.session_id` (spec 5.10's `_sessionid`) for a live
session, or your own durable run id for a process-less host. Scoping is
mandatory, not advisory: `send_counter` restarts at 0 for every
`%MachineState{}` (`Statifier.MachineState`'s "`send_counter` is the
session-global `send_` id sequence" moduledoc section, ADR-0035), so
`send_1` from one run collides with `send_1` from a completely unrelated run
unless your store keeps them apart. The library cannot supply this scope
itself - it has no view of your store - which is why it is your first
design decision, not the library's.

`c_index` and `owner` (fields on `Statifier.Effect.SendDelayed`) are
mandatory parts of the dedup key, not decoration. They name the `<send>`
content node's position and which executable-content block emitted it. A key
built from only `session scope`, `send_id`, `macrostep`, `microstep`, and
`round` collides whenever one `<onentry>` (or any other block) executes two
delayed sends with the same author-written `id` in the same microstep: both
share every one of those five fields, and only `c_index`/`owner` tell them
apart.

`ordinal` is what makes the key per-instance where the other seven
components cannot. A `<send id="x" delay="...">` written inside a
`<foreach>` body executes once per iteration from the same content position
- `<foreach>`'s own content runner re-executes the same static,
document-order `c_index` list on every iteration
(`lib/statifier/machine/content/foreach.ex`) - so every iteration's send
carries the *same* `c_index`, the *same* `owner`, and (the id being
author-written) the *same* `send_id`, all from the same microstep. Only
`ordinal` tells those apart: it is minted from
`machine_state.timer_counter`, a session-global counter that advances on
every `%SendDelayed{}` or `%Cancel{}` construction and replays
deterministically for the same reason `send_counter` does (pure fold state,
ADR-0035's argument; decided by ADR-0059). `%Cancel{}` carries the same
`ordinal` field for the same reason - two cancels of the same `send_id`
from two iterations are distinct effects your store must not collapse into
one, or a send scheduled between them keeps a timer the chart cancelled.

Because `timer_counter` is monotone and session-global,
`{session scope, ordinal}` is already unique on its own; ADR-0059 blesses
that pair as a compact key, with the remaining fields kept as row data. The
full compound form stays the documented default because a self-describing
row is worth more during an incident than a bare sequence number.

## Termination: what you owe that the library used to give you

Spec 6.2, quoted verbatim from the local spec cache:

> If the SCXML session terminates before the delay interval has elapsed, the
> SCXML Processor MUST discard the message without attempting to deliver it.

Inside the library, `Statifier.Session`'s `terminate/2`
satisfies this unconditionally: every live timer ref is cancelled before the
process exits. A durable scheduler inverts the whole premise by design - it
deliberately survives process death, which is the entire point of using one
- so nothing plays the role `terminate/2` played. ADR-0054 decision 4 states
what replaces it: **before feeding a fired event back, the host MUST
establish that the run is still live, and discard the message without
delivering it otherwise.** A cancel-on-run-end hook is worth running to keep
your store tidy, but it is never load-bearing by itself - the node death
that durability exists to survive takes the hook down with it. The guarantee
can only be enforced at delivery time.

"Live" is stricter than "not terminated." Reaching `:done` sets
`state.halted` but does not stop the session process (`lib/statifier/session.ex`
"`:done` idles the session"); the library discards its own in-process timers
at the halt (`discard_pending_timers/2`) precisely because an idled
process may never reach `terminate/2` - but that discard never reaches a
durable store, and `handle_continue(:drain, ...)` declines to drain onto a
halted session, so an event fed to a halted session just sits queued rather
than being discarded. Checking only "is the process alive" misses this case
entirely. (One further wrinkle mirrored from the library: `:budget_exhausted`
halts the session while the core is still `running` and cancellable, and the
library keeps its own timers armed there - a durable host that wants parity
treats budget-halted as live for delivery until a cancel lands.)

The check is **two steps, in order**, because `Statifier.Session.status/1` is
a `GenServer.call` that **exits** the
caller when the target process no longer exists - it cannot itself answer
"terminated?", since asking it that question against a dead session crashes
the asker instead of returning an answer.

**Step 1: terminated?** Resolve the session id through the registry -
`Registry.lookup(Statifier.Registry, session_id)` (ADR-0027 decision 2,
`Statifier.Session`'s "`<send>` routing" moduledoc section). An empty
result means discard the
message; the session no longer exists (or never registered), so `status/1`
is not safe to call. If your host holds a pid instead of a session id,
`Process.alive?/1` answers the same question directly. Only once this step
confirms a live process do you move to step 2 - calling `status/1` directly
without it turns a required discard into a crashed worker.

**Step 2: halted?** With a live process confirmed, call
`Statifier.Session.status/1`:

```elixir
@spec status(server :: Statifier.Session.server()) :: Statifier.Session.status()
def status(server)
```

(`Statifier.Session.status/1`), returning a map whose `:status` field
is one of `:running | :done | :cancelled | :budget_exhausted`. Anything but
`:running` is the halted case from above and must be discarded the same way.

A worked liveness check, terminated first:

```elixir
def deliver_fired_job(session_id, event) do
  case Registry.lookup(Statifier.Registry, session_id) do
    [] ->
      # Step 1: terminated (or never registered) - discard, per spec 6.2.
      MyApp.TimerStore.mark_discarded(event, :terminated)
      :ok

    [{pid, _value}] ->
      # Step 2: live process confirmed - status/1 is now safe to call.
      case Statifier.Session.status(pid) do
        %{status: :running} ->
          Statifier.Session.send_event(pid, event)

        %{status: other} ->
          # :done, :cancelled, or :budget_exhausted - discard, per spec 6.2.
          MyApp.TimerStore.mark_discarded(event, other)
          :ok
      end
  end
end
```

A process-less host has no process to ask, so it checks the same two
conditions against its own persisted position instead - whatever it stores
as the run's terminated/halted state - before feeding the fired event into
its next drive.

## Correlating a fired job back to its position

When your scheduler fires a job, it needs to know which macrostep,
microstep, round, `c_index`, and `owner` the send was scheduled from, so the
re-entered event can be attributed back to the right point in the run. Read
those off the `%SendDelayed{}` you stored when the send was scheduled -
**never** off anything computed at delivery time. ADR-0046 stamps
`macrostep`, `microstep`, and `round` "as they stood when the send was
scheduled, not when the timer fires" (`Statifier.Effect.SendDelayed`'s
moduledoc), and `c_index`/`owner` are static content-node identity, not
recomputed at delivery either. This is also what makes the dedup key above
deterministic across a re-run: the position you stored is the position, full
stop, regardless of when or how many times the job actually fires.

## Ordering guarantees you can rely on

`Statifier.Session`'s subscriber stream delivers effects in non-decreasing
`(macrostep, round)` order, and a re-entry's effects never arrive ahead of
the outer batch that triggered it (`Statifier.Session`'s "One subscriber
stream" moduledoc section, ADR-0044 decision 1). That section once also
carried a caveat that `round` was stamped only on `Statifier.Effect.Trace.*`
and `Statifier.Effect.BudgetExhausted`; **ADR-0046 withdrew it** ("every core
effect carries `round`"), so it does not apply to what you store: `round` is
an `@enforce_keys` field on every `%SendDelayed{}` you read, which is exactly
what the dedup key above rests on.

`{:halted, reason}` is end-of-stream on the subscriber channel (ADR-0044
decision 2) - see "Route A" above for the full statement; no cleanup effects
arrive after a halt.

What the ordering guarantee promises is about the **stream your subscriber
sees**, not about wall time: it tells you the order your `SendDelayed`/`Cancel`
effects arrive relative to each other and to everything else in the run, not
when your durable scheduler will actually fire a job relative to any other
job. Two timers scheduled ten milliseconds apart in `(macrostep, round)`
order carry no promise about firing ten milliseconds apart, or in that order
at all, once they leave the effect stream and enter your own scheduler's
clock.

## Where this is going

The chartered `statifier_oban` package is the packaged consumer of exactly
this recipe - an Oban-backed implementation of Route A, keyed and
liveness-checked per ADR-0054. If you are building an invoke handler
alongside your durable timers, its own at-least-once contract lives in
`docs/extending.md` ("At-least-once: handlers must be idempotent"),
not here - the two seams share a host but not a rulebook.
