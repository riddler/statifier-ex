# How to make a delayed send outlive the process

**Read this to:** make a `<send delay="...">` survive a node restart, a deploy,
or a crash. You are a host application author.

**Short version:** consume the `SendDelayed` and `Cancel` effects, store them
under the keys below, and check that the session is live before you deliver a
fired event.

You take over scheduling from `Statifier.Session`. This guide shows the two
effects, the two ways to consume them, and the contract you accept. For the
interpreter itself, see [architecture.md](architecture.md).

## Why you would want this

`Statifier.Session` schedules a delayed send with `Process.send_after/3`. This
is the library's one call to it. It is in the `{:schedule, ...}` clause of
`perform_instruction/3` in `Statifier.Session`. The timer lives in the BEAM
timer wheel and is tied to the session process. It dies with the node.

- For delays of a few seconds, this is rarely a problem.
- For a follow-up, an escalation, or a timeout of hours or days, it is a
  problem. A deploy or a crash between scheduling and firing drops the send
  silently.

ADR-0003 (Consequences) allowed this substitution on the day the effect
boundary was decided: "Embedders can supply their own effect interpreter (e.g.
queue delayed sends into Oban instead of process timers)." That sentence named
the destination. This guide and ADR-0054 are the way there. ADR-0054 is the
contract that this guide teaches. Read it once with this guide for the reason
behind each rule, not only the rule.

Decision: [ADR-0003](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0003-pure-core-with-effects.md),
[ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md).

## What you consume

Two members of the public effect vocabulary (`lib/statifier/effect.ex`) form
the whole seam.

`Statifier.Effect.SendDelayed` (`lib/statifier/effect/send_delayed.ex`):

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

`delay_ms` is relative. It counts milliseconds from the moment the send was
scheduled. It is not an absolute deadline. Your store must compute or record
the fire time itself.

`Statifier.Effect.Cancel` (`lib/statifier/effect/cancel.ex`):

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

Two fields on both structs need a rule:

- **`ordinal`.** A per-execution sequence number from
  `machine_state.timer_counter`. A `<foreach>` body can execute the same
  `<send delay>` or `<cancel>` node many times. The `ordinal` keeps these
  executions distinct in your dedup key.
  Decision: [ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md).
- **`caller_context`.** The opaque host slot. It holds the correlation term
  that the triggering external event of the current macrostep carried, for
  example an OTel span context or a request id. The library copies it onto the
  effect and never reads it. `nil` means no context was attached.
  - Store it as row data beside the key components.
  - Never make it a key component. An opaque host term is not comparable across
    hosts, is not bounded, and does not affect the identity of a replay.
  - Read it back at firing or cancellation time, so the firing site can link
    to the trace that scheduled the timer.

  Decision: ADR-0063 decision 6.

These two effects are the only things that a durable-timer host reads.

**Do not read the instruction vocabulary.** The atoms `{:schedule, ...}` and
`{:cancel_timers, ...}` (`@type instruction` in `Statifier.Session.Effects`)
are internal. Their names look like an obvious match for "schedule a timer" and
"cancel a timer", but they are not yours to read. `Statifier.Session` uses them
to perform `Process.send_after/3` and `Process.cancel_timer/1`. If you see them
in a stack trace or a `:telemetry` payload, do not intercept them. Consume the
effect, not the instruction.
The general rule is in `docs/extending.md:58-59`: "The instruction vocabulary
a planning callback returns is opaque outside the library." ADR-0054
decision 1 applies it to timers by name.

## Route A: a live session

If you run `Statifier.Session` processes, subscribe to one and pattern-match
the two effects from the stream. Schedule a `SendDelayed` effect only when its
`target` is `nil`. Ignore any other target.

**Why only `nil`.** `plan_send_delayed/3` (`lib/statifier/session/effects.ex`)
resolves `send.target` into a route:

- `:self` for `nil`
- `:internal` for `#_internal`
- `:parent` for `#_parent`
- `{:session, id}` for `#_scxml_<id>`
- `{:invoke, id}` for any other `#_`-prefixed target

The route travels on the opaque `{:schedule, ...}` instruction (ADR-0054
decision 1 forbids you to read it). It never appears on the `%SendDelayed{}`
effect. On the struct, `target` is the raw
string the author wrote, or `nil`. No string means "self" the way `nil` does.

**Who delivers.** `deliver_fired/4` (`lib/statifier/session.ex`) handles
`:self` alone. It re-enqueues onto the inbox of the session. Every other route
goes through `deliver/5`. The session builds the delivered event, not you:

- `delivered_event/2` (`effects.ex`) stamps `origin`, `origintype`, and
  `sendid` for the ordinary case.
- `#_internal` uses a different carrier, `internal_event/1` (`effects.ex`).
  Its delivery re-raises through `Statifier.Interpreter.deliver_internal/5`.

No public door outside the session rebuilds this for `#_parent`,
`#_invokeid`, `#_internal`, or an external session id. Leave those targets to
the library. Ignoring an effect costs nothing, because the effect stream is
observational. The `Process.send_after/3` timer of the session still fires it.

**This limit is permanent.** It is a decision, not pending work. The ADR makes
it permanent for `#_parent`, `#_invokeid`, and `#_internal`. Those routes name
the live process bookkeeping of the sending session, and a durable timer
outlives that process by definition. The ADR defers the external-session route
until a named trigger occurs.

If a document needs a durable delayed send to reach its parent or an invoked
child, change the document. Delay a send to yourself. Let the transition that
it triggers do an immediate `<send target="#_parent">` from the live session.

Decision: [ADR-0055](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md).

**End of stream.** `{:halted, reason}` is the last message on the subscriber
channel. After it, no more effects arrive for that session id, cleanup effects
included. Do not wait for one.
Decision: ADR-0044 decision 2 (`Statifier.Session`, "One subscriber stream").

**Subscribe.** `Statifier.Session.subscribe/2` and `subscribe/3`:

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

The library plans every effect the core produces to a `{:notify, effect}` at
its original fold position. The subscriber stream is therefore the complete,
ordered list of effects. You need no second channel. A subscriber process
receives `{:statifier, session_id, {:effect, effect}}` messages. This minimal
example enqueues and cancels against a host store:

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

**Fire.** When your durable scheduler fires a job, feed the event back in with
`Statifier.Session.send_event/2`:

```elixir
@spec send_event(server :: Statifier.Session.server(), event :: Statifier.Event.t() | String.t()) ::
        :ok
def send_event(server, event)
```

A fired in-process timer uses the same door. `deliver_fired/4`
(`lib/statifier/session.ex`) re-enqueues onto the inbox of the session
"exactly as `send_event/2` does". Your scheduler adds no second re-entry path.

`send_event/2` is a `GenServer.cast`, like every write door on
`Statifier.Session`. No synchronous variant exists. Do not block your job
worker to wait for a reply. The session queues the event behind the events
that already wait.

## Route B: a process-less host

Use this route if you do not run `Statifier.Session`. You drive
`Statifier.Interpreter` directly against a persisted `%MachineState{}`. You
read the same two effects from the `[effect]` half of the interpreter's return
value. You do not subscribe to anything. `SendDelayed` and `Cancel` appear in
the returned list in the same order as in the subscriber stream of a live
session. `docs/extending.md:44-50` describes the same audience for `<invoke>`
handlers: "This is what lets a durable host that drives `Statifier.Interpreter`
directly, with no `Statifier.Session` process at all, plan invocations the same
way `Statifier.Session` does."

The fired event is the input to the next drive of your host. No function call
delivers it, because no running process exists to call.

**Persist the position between drives.** Use the library format:

- `Statifier.Position.to_binary/1` writes a `%MachineState{}` to a
  version-stamped, identity-checked blob.
- `Statifier.Position.from_binary/2` reads it back against the compiled
  `Machine`. It refuses with a typed error on a format-version or
  chart-identity mismatch.
- `routes`, `invoke_types` and `send_types` come back as `nil` on purpose.
  They are per-driver snapshots, not durable position state. Re-stamp them
  before the next drive.

Do not invent your own format. For the identity checks, the migration stories,
and the rehydration recipe, read [persistence.md](persistence.md).

Decision: ADR-0052, ADR-0060, ADR-0064.

## Keying your store

`send_id` alone does not identify a timer uniquely. Use two keys.

| Purpose | Key | Why |
|---|---|---|
| Cancellation | `{session scope, send_id}` | The key can match more than one stored row. `Statifier.Session.Timers.put/3` appends per `send_id` in scheduling order. `take/2` pops every ref under an id, because spec 6.3 says a cancel with a given sendid cancels them all. An author-written `id` is reused verbatim and never advances `send_counter` (`generate_send_id/2` in `lib/statifier/machine/content/send.ex`). One `<send id="x" delay="...">` executed twice therefore produces two live timers under one `send_id`. A cancel that matches nothing is a no-op, not an error. Mirror `take/2`'s `{[], timers}`. |
| Deduplication (at-least-once) | `{session scope, send_id, macrostep, microstep, round, c_index, owner, ordinal}` | Read the key from the stored `%SendDelayed{}`. The counters and positions are stamped as of scheduling, not firing (ADR-0046). `ordinal` is a per-execution sequence from `machine_state.timer_counter` (ADR-0059). Every component is deterministic: no clock, no CSPRNG, no pid. A re-execution of the same drive after a crash produces a byte-identical key, so the dedup check of your store is sound. |

Decision: ADR-0054 decision 3.

**Session scope.** For a live session, it is `ctx.session_id` (spec 5.10's
`_sessionid`). For a process-less host, it is your own durable execution id.
You must scope the key. `send_counter` restarts at 0 for every
`%MachineState{}` (`Statifier.MachineState`, "`send_counter` is the
session-global `send_` id sequence"). Without a scope, `send_1` from one
execution collides with `send_1` from an unrelated execution. The library
cannot supply the scope, because it has no view of your store. It is your first
design decision, not the library's.
Decision: ADR-0035.

**`c_index` and `owner`.** These fields of `Statifier.Effect.SendDelayed` are
required parts of the dedup key. They name the position of the `<send>`
content node and the executable-content block that emitted it. A key built
from only `session scope`, `send_id`, `macrostep`, `microstep`, and `round`
collides when one `<onentry>` (or any other block) executes two delayed sends
with the same author-written `id` in the same microstep. Both sends share all
five of those fields. Only `c_index` and `owner` tell them apart.

**`ordinal`.** It makes the key per-instance where the other seven components
cannot. A `<send id="x" delay="...">` inside a `<foreach>` body executes once
per iteration from the same content position. The content runner of
`<foreach>` re-executes the same static, document-order `c_index` list on
every iteration (`lib/statifier/machine/content/foreach.ex`). Every iteration
therefore carries the same `c_index`, the same `owner`, and (because the
author wrote the id) the same `send_id`, all from the same microstep. Only
`ordinal` tells them apart.

The library mints `ordinal` from `machine_state.timer_counter`. This
session-global counter advances on every `%SendDelayed{}` or `%Cancel{}`
construction. It replays deterministically for the same reason that
`send_counter` does: it is pure fold state (the argument of ADR-0035, decided
by ADR-0059).

**Cancels.** `%Cancel{}` carries the same `ordinal` for the same reason. Two
cancels of the same `send_id` from two iterations are distinct effects. Your
store must not collapse them into one. If it does, a send scheduled between
them keeps a timer that the chart cancelled.

**Compact key.** `timer_counter` is monotone and session-global, so
`{session scope, ordinal}` is already unique. ADR-0059 allows that pair as a
compact key, with the remaining fields kept as row data. The full compound
form stays the documented default. A self-describing row is more useful
during an incident than a bare sequence number.

## Lifetime across resume, revision, and restart

A pending delayed send is identified by `{session scope, send_id}`, the
cancellation key above. It lives until one of these events occurs:

- It fires.
- It is cancelled.
- Its execution is not live at fire time. See "Termination" below.

The table shows what happens to the session scope, your stored rows, and the
library timer table across the three ways an execution identity can change.

| Transition | Session scope | Your stored rows | Library's own timer table |
|---|---|---|---|
| Resume | Unchanged. The position's `_sessionid` is kept by default (ADR-0060 decision 3) | Still meaningful. Nothing about the key moved | Empty (ADR-0060 decision 7): no live timer comes back with the process |
| Chart revision (export/import) | Unchanged. A revision change does not touch `_sessionid` | Still meaningful. Send ids carry no state index and chart identity joins no key (ADR-0063 decision 6). The identity gate (ADR-0052, ADR-0060 decision 2) decides whether the *position* can resume at all, never the timer key | N/A: governed by whichever of the other two rows applies |
| Restart (fresh process) | Fresh. `MachineState.new/2` mints a new `sess_` id on `start_link/2` (ADR-0027 decision 4) | Orphaned. The old scope can never match a live execution again, so the fire-time liveness check (ADR-0054 decision 4) discards them | Empty. The delayed-send timers of the old process die with it |

**Resume.** Your store carries the pending send across the gap.

- Every row under the pre-resume scope keeps its meaning. You re-key nothing.
- The library timer table does not come back. `Session.Timers.new()` starts
  empty on a resumed session. This is why a durable host exists. You must
  re-arm the pending sends that your store still holds. The library does not
  do this for you.
- A `<cancel sendid="x"/>` executed after a resume still emits a
  `%Statifier.Effect.Cancel{send_id: "x"}` on the effect stream, although the
  resumed timer table never held anything under "x". The pure core emits the
  cancel effect when it executes the `<onexit>` or `<onentry>` content of the
  chart. It does not know or check whether a timer table is populated. Your store cancels the pre-resume row on
  this effect. `test/statifier/session/resume_test.exs` pins this behavior.

**Chart revision.** The key does not move. Migrating a position across chart
revisions (the export/import process in [persistence.md](persistence.md)) does
not change `{session scope, send_id}`. Send ids are author-written and carry
no state index, and chart identity is not a component of the key. ADR-0063
decision 6 makes the same "row data, never a key component" argument for
`caller_context`. A key holds only components that are relevant to identity and
deterministic on replay. The identity check on the position does gate a
revision change, at resume time. It decides whether the position can resume at
all. It does not affect the timer key.

**Restart.** A restart is not a resume, and it mints a fresh scope. A
supervisor restart runs `start_link/2` again. `MachineState.new/2` mints a
fresh `sess_` UXID, and the delayed-send timers of the prior process are gone.
The stored rows of the old scope can never match a live execution again. The
fire-time liveness check discards them. It also discards the rows of a
terminated execution. A restart needs no key-level handling beyond that check.

Decision: ADR-0060 decision 3 ("ADR-0027 decision 4's 'a restart generates a
fresh `sess_` id' governs restarts, not resumes"), ADR-0027 decision 4.

## Termination: what you owe that the library used to give you

Spec 6.2, quoted verbatim from the local spec cache:

> If the SCXML session terminates before the delay interval has elapsed, the
> SCXML Processor MUST discard the message without attempting to deliver it.

Inside the library, `terminate/2` of `Statifier.Session` satisfies this rule
without exception. It cancels every live timer ref before the process exits. A
durable scheduler survives process death, so nothing replaces `terminate/2`.
Before you feed a fired event back, the host MUST establish that the execution
is still live. Otherwise it MUST discard the message without delivering it.
Decision: ADR-0054 decision 4.

A cancel-on-execution-end hook keeps your store tidy, so run one. Do not rely
on it alone. The node death that durability must survive also takes the hook
down. You can enforce the guarantee only at delivery time.

**"Live" means more than "not terminated".**

- Reaching `:done` sets `state.halted`, but it does not stop the session
  process (`lib/statifier/session.ex`, "`:done` idles the session"). The
  library discards its own in-process timers at the halt
  (`discard_pending_timers/2`), because an idled process may never reach
  `terminate/2`. That discard does not reach a durable store.
- `handle_continue(:drain, ...)` does not drain onto a halted session. An
  event fed to a halted session stays queued and is not discarded.
- `:budget_exhausted` halts the session while the core is still `running` and
  cancellable. The library keeps its own timers armed in that state. A durable
  host that wants the same behavior treats a budget-halted session as live for
  delivery until a cancel lands.

A check of only "is the process alive" misses the first two cases.

**The check has two steps, in this order.** `Statifier.Session.status/1` is a
`GenServer.call`. It exits the caller when the target process no longer
exists, so it cannot answer "terminated?".

1. **Terminated?** Resolve the session id through the registry with
   `Registry.lookup(Statifier.Registry, session_id)`. An empty result means
   the session no longer exists, or it never registered. Discard the message.
   Do not call `status/1`. If your host holds a pid, `Process.alive?/1`
   answers the same question. A direct call to `status/1` without this step
   turns a required discard into a crashed worker.
   Decision: ADR-0027 decision 2 (`Statifier.Session`, "`<send>` routing").
2. **Halted?** After you confirm a live process, call
   `Statifier.Session.status/1`:

   ```elixir
   @spec status(server :: Statifier.Session.server()) :: Statifier.Session.status()
   def status(server)
   ```

   It returns a map. Its `:status` field is one of
   `:running | :done | :cancelled | :budget_exhausted`. Any value except
   `:running` is the halted case. Discard the message in the same way.

This worked check tests for termination first:

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

A process-less host has no process to ask. It checks the same two conditions
against its own persisted position, using whatever it stores as the terminated
or halted state of the execution. It does this before it feeds the fired event
into its next drive.

## Correlating a fired job back to its position

When your scheduler fires a job, you must know the macrostep, microstep,
round, `c_index`, and `owner` that the send was scheduled from. With these you
can attribute the re-entered event to the correct point in the execution.

- Read the values from the `%SendDelayed{}` that you stored at scheduling
  time. Never read them from anything computed at delivery time.
- `macrostep`, `microstep`, and `round` are stamped "as they stood when the
  send was scheduled, not when the timer fires" (`Statifier.Effect.SendDelayed`
  moduledoc, ADR-0046).
- `c_index` and `owner` are static content-node identity. The library does not
  recompute them at delivery.

The stored position is the position, regardless of when the job fires or how
many times it fires. This also keeps the dedup key deterministic across a
re-run.

## Ordering guarantees you can rely on

The subscriber stream of `Statifier.Session` delivers effects in
non-decreasing `(macrostep, round)` order. The effects of a re-entry never
arrive before the outer batch that triggered it
(`Statifier.Session`, "One subscriber stream", ADR-0044 decision 1).

That section once carried a caveat: `round` was stamped only on
`Statifier.Effect.Trace.*` and `Statifier.Effect.BudgetExhausted`. ADR-0046
withdrew it ("every core effect carries `round`"), so it does not apply to what
you store. `round` is an `@enforce_keys` field on every `%SendDelayed{}` you
read. The dedup key depends on this.

`{:halted, reason}` is the end of the stream. See "Route A" above.

The guarantee applies to the stream that your subscriber sees. It does not
apply to wall time. It tells you the order in which your `SendDelayed` and
`Cancel` effects arrive, relative to each other and to all other effects in
the execution. It does not tell you when your durable scheduler fires one job
relative to another. Assume two timers scheduled ten milliseconds apart in
`(macrostep, round)` order. After they enter the clock of your own scheduler,
nothing promises that they fire ten milliseconds apart, or in that order.

## Where this is going

The chartered `statifier_oban` package is the packaged consumer of this
recipe. It is an Oban-backed implementation of Route A, keyed and
liveness-checked per ADR-0054. If you build an invoke handler beside your
durable timers, its at-least-once contract is in
[extending.md](extending.md) ("At-least-once: handlers must be idempotent").
The two seams share a host but not a rulebook.
