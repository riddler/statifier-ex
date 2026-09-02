# Hosting the Pure Core Without `Statifier.Session`

How to drive a chart with no session process anywhere: what your driver owes
the interpreter for each effect it returns, how timers and `<invoke>`
handlers work when there is nothing to call into, when a position is safe to
write down, and how to make your driver visible to the same telemetry a
session-hosted run produces.

`Statifier.Session` is one driver of a chart, not the definition of one
([ADR-0067](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md)
decision 1). The pure core is a fold: hand
`Statifier.Interpreter` a `%Statifier.MachineState{}` and an event, get back
a new `%MachineState{}` and a list of effects. Nothing in that sentence needs
a process. A durable host - one that steps a chart from a job, persists the
result, and goes away until the next job wakes it - is a first-class,
supported way to run this library, and this guide is its contract.

Read this alongside, not instead of:

- [Persistence](persistence.md) - the identity hazard, the position blob,
  what a host must persist, and the process-less invoke answer recipe.
- [Durable timers](durable-timers.md) - Route B is the process-less half of
  delayed sends, including the store keying and the delivery-time liveness
  check.
- [Extending](extending.md) - writing and registering `<invoke>` handlers.
- [Observability](observability.md) and [OpenTelemetry](opentelemetry.md) -
  what the trace effects carry and what the bridge does with them.

## What you take on, and what you get

A session process does six jobs. Driving the core yourself means doing all
six, and the rest of this guide is one section per job that is not obvious.

| Job | `Statifier.Session` does it by | You do it by |
|---|---|---|
| Holding the position | keeping `%MachineState{}` in process state | persisting a position blob between drives ([Persistence](persistence.md)) |
| Advancing the chart | calling an `Interpreter` entry from a callback | calling the same entry from your job/handler |
| Acting on effects | planning then performing them | planning then performing them - the plan half is public, see below |
| Timers | `Process.send_after/3` and a per-session timer table | your own durable scheduler ([Durable timers](durable-timers.md) Route B) |
| `<invoke>` lifecycle | an in-memory invocation table and two answer doors | your own invocation rows and `Statifier.Invoke.Answer` |
| Telemetry | emitting through `Statifier.Telemetry` with `driver: :session` | emitting through the same module with your own driver atom |

What you get in exchange is the reason to do it: a run that survives node
death, a step that is a database transaction, and a chart whose progress is
a row rather than a process. `statifier_persistence` is exactly this driver,
built once so most hosts do not have to - see "What you do not have to
build" at the end.

## The loop

Every process-less drive is the same four beats:

1. **Load.** Decode the position against the recompiled chart, and re-stamp
   the two per-drive snapshot fields.
2. **Advance.** Call one `Interpreter` entry with an event (or none).
3. **Execute.** Plan the returned effects into instructions and perform
   them.
4. **Persist.** Write the new position back, at quiescence.

Beat 1 is `Statifier.Interpreter`'s own "Rehydrating a position" section
(`lib/statifier/interpreter.ex:43-92`), which is the reference text for it
and is not restated here. In short: `Statifier.Position.from_binary/2`
(`lib/statifier/position.ex:158-164`) checks format version and chart
identity for you, and returns `routes` and `invoke_types` as `nil` on
purpose, so re-stamp both with
`Statifier.MachineState.put_routes/2` (`lib/statifier/machine_state.ex:854-855`)
and `put_invoke_types/2` (`lib/statifier/machine_state.ex:859-865`) before
the first advance.

Beat 2 has six doors, and a driver may use any of them - they all take a
`%MachineState{}` and trust it structurally, with no state of their own
outside that struct:

| Entry | Use it for | Defined at |
|---|---|---|
| `Statifier.Interpreter.initialize/2` | the run's very first drive, once ever | `lib/statifier/interpreter.ex:261-263` |
| `Statifier.Interpreter.handle_event/2` | an external event: a fired timer, an invoke answer, a host command | `lib/statifier/interpreter.ex:485-489` |
| `Statifier.Interpreter.deliver_internal/5` | an event routed to `#_internal` | `lib/statifier/interpreter.ex:547-557` |
| `Statifier.Interpreter.cancel/1` | Appendix D's `cancel` - stop the chart | `lib/statifier/interpreter.ex:929-933` |
| `Statifier.Interpreter.macrostep/1` | fold an already-queued position to quiescence | `lib/statifier/interpreter.ex:1100-1107` |
| `Statifier.Interpreter.microstep/1` | one round at a time, for a step debugger | `lib/statifier/interpreter.ex:1014-1031` |

`handle_event/2` returns `{:ok, machine_state, effects}` or
`{:error, :not_running}` - the `running` guard is Appendix D's own loop
condition, so a chart that has already terminated refuses the event rather
than pretending to consume it (`lib/statifier/interpreter.ex:485-487`).

### A minimal driver, end to end

The smallest honest driver: it plans the effects, performs the instructions
it understands, re-drives whatever the plan enqueued, and records the timer
rows and logs it owes the outside world. The chart arms a delayed send,
raises an immediate self-send, and terminates when the timer's event comes
back on a second drive.

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
       datamodel="predicator" initial="idle">
    <state id="idle">
        <transition event="start" target="working"/>
    </state>
    <state id="working">
        <onentry>
            <log label="phase" expr="'working'"/>
            <send event="settle" delay="50ms"/>
            <send event="working.entered"/>
        </onentry>
        <transition event="working.entered" target="waiting"/>
    </state>
    <state id="waiting">
        <transition event="settle" target="settled"/>
    </state>
    <final id="settled"/>
</scxml>
```

```elixir
defmodule MyApp.Driver do
  alias Statifier.{Effect, Event, Interpreter, MachineState}
  alias Statifier.Session.Effects

  defstruct timers: [], logs: [], halted: nil

  @typedoc "What one drive accumulated for the host to act on."
  @type t :: %__MODULE__{
          timers: [{String.t() | nil, pos_integer(), non_neg_integer(), String.t()}],
          logs: [{String.t() | nil, term()}],
          halted: :done | :budget_exhausted | :not_running | nil
        }

  @typedoc "The reduce accumulator: the position, what the drive gathered, and events still to re-drive."
  @type acc :: {MachineState.t(), t(), [Event.t()]}

  @doc """
  Drives one external event, performs the instructions the plan returns,
  and re-drives whatever those instructions enqueued, until nothing is
  left to feed in.
  """
  @spec drive(machine_state :: MachineState.t(), event :: Event.t(), acc :: t()) ::
          {MachineState.t(), t()}
  def drive(machine_state, %Event{} = event, acc \\ %__MODULE__{}) do
    case Interpreter.handle_event(machine_state, event) do
      {:ok, machine_state, effects} ->
        effects
        |> Effects.plan(plan_context(machine_state))
        |> Enum.reduce({machine_state, acc, []}, &perform/2)
        |> drain()

      {:error, :not_running} ->
        {machine_state, %{acc | halted: :not_running}}
    end
  end

  @spec plan_context(machine_state :: MachineState.t()) :: Effects.context()
  defp plan_context(machine_state) do
    %{
      session_id: machine_state.datamodel["_sessionid"],
      invoke_types: machine_state.invoke_types,
      invoke_handlers: %{},
      invocation_types: %{}
    }
  end

  @spec perform(instruction :: Effects.instruction(), acc :: acc()) :: acc()
  defp perform({:enqueue_event, event}, {machine_state, acc, queued}),
    do: {machine_state, acc, queued ++ [event]}

  defp perform({:schedule, send_id, delay_ms, _route, event, effect}, {ms, acc, queued}) do
    {:send_delayed, delayed} = effect
    row = {send_id, delayed.ordinal, delay_ms, event.name}
    {ms, %{acc | timers: acc.timers ++ [row]}, queued}
  end

  defp perform({:cancel_timers, send_id}, {machine_state, acc, queued}) do
    kept = Enum.reject(acc.timers, &match?({^send_id, _ordinal, _delay, _name}, &1))
    {machine_state, %{acc | timers: kept}, queued}
  end

  defp perform({:notify, {:log, %Effect.Log{} = log}}, {machine_state, acc, queued}),
    do: {machine_state, %{acc | logs: acc.logs ++ [{log.label, log.value}]}, queued}

  defp perform({:halt, reason}, {machine_state, acc, queued}),
    do: {machine_state, %{acc | halted: reason}, queued}

  defp perform(_instruction, state), do: state

  @spec drain(acc :: acc()) :: {MachineState.t(), t()}
  defp drain({machine_state, acc, []}), do: {machine_state, acc}

  defp drain({machine_state, acc, [event | rest]}) do
    {machine_state, acc} = drive(machine_state, event, acc)
    drain({machine_state, acc, rest})
  end
end
```

Two drives against that chart:

```elixir
{:ok, machine} = Statifier.compile(chart_source)
{machine_state, _effects} = Statifier.Interpreter.initialize(machine)

# Drive one: the host's own "start" command.
{machine_state, acc} = MyApp.Driver.drive(machine_state, Statifier.Event.external("start"))
#=> acc.logs   == [{"phase", "working"}]
#=> acc.timers == [{send_id, 1, 50, "settle"}]
#=> Statifier.active_leaf_states(machine_state) == MapSet.new(["waiting"])

# Drive two: later, the host's scheduler fires the row it stored above.
{machine_state, acc} = MyApp.Driver.drive(machine_state, Statifier.Event.external("settle"), acc)
#=> acc.halted == :done
```

The module and both drives are pinned by
`test/statifier/hosting_without_session_test.exs`, which holds the same
chart and the same code; if one changes, change both.

Two things this example is deliberately not: it holds the position in a
variable rather than persisting it (beats 1 and 4 are
[Persistence](persistence.md)'s job), and it registers no `<invoke>`
handlers. Add those and it is a real durable driver.

## The driver contract, effect by effect

`Statifier.Effect` is the whole vocabulary in one module - eleven core
effects and ten trace effects, as one `@type t()` union
(`lib/statifier/effect.ex:121-149`), with the table naming which interpreter
function produces each at `lib/statifier/effect.ex:23-45`. Every effect is a
`{tag, payload_struct}` two-tuple; `Statifier.Effect.trace?/1`
(`lib/statifier/effect.ex:157-159`) is the single match that separates trace
from core.

Trace effects are ordinary members of the same list, in the same order -
there is no side channel to keep in sync
(`lib/statifier/effect.ex:67-71`).

What a driver **owes** each effect. "Owes" here means: the chart's behavior
is wrong, or an author-visible obligation is unmet, if you skip it.

| Effect | Payload | What a driver owes it |
|---|---|---|
| `:send` | `Statifier.Effect.Send` (`lib/statifier/effect/send.ex:49-74`) | Deliver the event to the resolved target. A `<send>` with no `target` is a self-send and comes back in as this run's own next external event; `#_internal` goes through `deliver_internal/5`; a session/parent/invoke target is your routing problem. Unsupported type or unparseable target is `error.execution` on the sender's own internal queue |
| `:send_delayed` | `Statifier.Effect.SendDelayed` (`lib/statifier/effect/send_delayed.ex:42-57`) | Store a durable timer row and arm your scheduler. See "Timers" below |
| `:cancel` | `Statifier.Effect.Cancel` (`lib/statifier/effect/cancel.ex:38-48`) | Cancel every stored row under that `send_id`, in your store. A cancel matching nothing is a no-op, not an error |
| `:invoke` | `Statifier.Effect.Invoke` (`lib/statifier/effect/invoke.ex:62-76`) | Start the invocation through its registered handler, and record an invocation row of your own (id, type, and the `caller_context` the core stamped) |
| `:cancel_invoke` | `Statifier.Effect.CancelInvoke` (`lib/statifier/effect/cancel_invoke.ex:45`) | Stop that invocation through its handler and drop your row. An unknown id is a silent no-op |
| `:autoforward` | `Statifier.Effect.Autoforward` (`lib/statifier/effect/autoforward.ex:36`) | Forward the carried event to that invocation **unmodified** (spec 6.4.2). A miss is a silent no-op |
| `:done` | `Statifier.Effect.Done` (`lib/statifier/effect/done.ex:33-42`) | Mark the run terminated. Emitted by `exit_interpreter/1`; nothing further will advance. Record `donedata`, and `donedata_error` alongside it - a failed `<donedata>` resolution and a bare final both leave `donedata: :undefined`, and only that second field tells them apart (ADR-0021's 2026-09-02 note) |
| `:budget_exhausted` | `Statifier.Effect.BudgetExhausted` (`lib/statifier/effect/budget_exhausted.ex:38`) | Mark the run halted on the macrostep-round budget. The core is still `running` and still cancellable - do not treat it as `:done` |
| `:log` | `Statifier.Effect.Log` (`lib/statifier/effect/log.ex:24`) | Write it wherever your host writes `<log>`. Nothing in the chart depends on it |
| `:datamodel_change` | `Statifier.Effect.DatamodelChange` (`lib/statifier/effect/datamodel_change.ex:60-72`) | Nothing is owed - the write already happened in the `%MachineState{}` you were handed. It is an observation seam |
| `:datamodel_init` | `Statifier.Effect.DatamodelInit` (`lib/statifier/effect/datamodel_init.ex:38`) | Nothing is owed, same reason: the starting baseline, for observers |
| `:trace` (ten) | `Statifier.Effect.Trace.*` (`lib/statifier/effect.ex:135-146`) | Nothing is owed. Forward them to observers if you want them, drop them if you do not; they are only produced when the position carries `trace: true` |

Three of those rows are the whole reason a driver is more than a `for`
loop - `:send_delayed`, `:invoke`, and `:cancel_invoke` are the ones with
durable state on your side of the boundary.

### Do not re-derive the routing: `Statifier.Session.Effects.plan/2`

The rules above - which `<send>` target means what, when an unsupported type
is `error.execution` rather than `error.communication`, which handler a
`:cancel_invoke` dispatches to - are already implemented, purely, in a
module a process-less driver can call. `Statifier.Session.Effects.plan/2`
(`lib/statifier/session/effects.ex:196-200`) takes the effect list and a
plain map and returns an ordered list of instructions
(`lib/statifier/session/effects.ex:165-179`). It touches no process, holds
no state, and is public precisely so an embedder can hand it effects
(`lib/statifier/session/effects.ex:15-23`).

Its second argument is the plan context
(`lib/statifier/session/effects.ex:158-163`):

```elixir
%{
  session_id: machine_state.datamodel["_sessionid"],
  invoke_types: machine_state.invoke_types,
  invoke_handlers: %{"myapp:capture" => MyApp.CaptureHandler},
  invocation_types: %{"inv_3" => "myapp:capture"}
}
```

`invocation_types` is your live `invoke_id => type` snapshot, built from
your own invocation rows - it is what lets a `:cancel_invoke` or an
`:autoforward` reach the same handler that started the invocation
(ADR-0051 decision 6).

The instructions it returns, and what performing each one means for a
process-less host:

| Instruction | Perform it by |
|---|---|
| `{:notify, effect}` | one per effect, in the core's own order - hand it to your observers, your telemetry, or nothing |
| `{:enqueue_event, event}` | feed it to this run's next drive (a self-send) |
| `{:deliver, route, event, effect}` | route it: `:internal` goes through `deliver_internal/5`, everything else is your addressing scheme |
| `{:raise, kind, name, origin, opts}` | raise that platform event on this run's own internal queue, through `deliver_internal/5` |
| `{:schedule, send_id, delay_ms, route, event, effect}` | write the durable timer row and arm your scheduler |
| `{:cancel_timers, send_id}` | delete every row under that `send_id` |
| `{:start_child, invoke, effect}` | start the child chart for a `type="scxml"` invocation |
| `{:forward, invoke_id, event}` | forward the event to that invocation, unmodified |
| `{:stop_child, invoke_id}` | stop that invocation; unknown id is a no-op |
| `{:handler, module, term}` | your handler's own instruction, opaque to the library - perform it yourself |
| `{:unroutable, effect}` | you could not route it; report it (see "Telemetry" below) |
| `{:halt, reason}` | `:done` or `:budget_exhausted` - mark the run terminated or halted |

Calling `plan/2` rather than re-implementing the table is the same argument
ADR-0067 decision 2 makes for telemetry: one implementation is what keeps
"the durable path behaves like the session path" a structural fact instead
of a review obligation.

## Timers: scheduling and cancelling delayed sends

A `%SendDelayed{}` is a request to deliver an event after `delay_ms`
milliseconds. No wall-clock instant is written anywhere - the library reads
no clock
([ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md)
decision 2) - so the deadline is yours to compute and yours to keep.
[ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md)
is the decision that a durable scheduler consumes this public effect
vocabulary rather than a seam of its own, and
[ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md)
adds the per-execution `ordinal` that makes a stored row uniquely
identifiable.

[Durable timers](durable-timers.md) is the full guide and its "Route B: a
process-less host" section is written for exactly this reader. The four
things it fixes, so you do not have to decide them:

1. **Two keys, not one.** Cancellation is keyed
   `{session scope, send_id}` and may match several rows; deduplication is
   keyed off the stored `%SendDelayed{}`'s own counters plus `ordinal`.
2. **Scope is mandatory.** `send_counter` restarts at 0 for every
   `%MachineState{}`, so `send_1` from two runs collides unless your store
   keeps them apart. Use the run's `_sessionid`.
3. **Attribution comes off the stored row**, never off anything computed at
   fire time - the counters were stamped when the send was scheduled.
4. **Liveness is checked at delivery.** Spec 6.2 requires a message be
   discarded if the session terminated before the delay elapsed, and a
   durable scheduler by design outlives the process that would have done
   that. A process-less host checks its own persisted terminated/halted
   state before feeding a fired event into the next drive.

A cancel is the mirror image: `%Cancel{}` carries the same `ordinal` field
for the same reason, so two cancels of one `send_id` from two `<foreach>`
iterations are distinct rows your store must not collapse.

## Invoke handlers with no session process

Handler registration was per-session by
[ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md),
and that stayed true when the session process stopped being the only
driver: the *registration* lives on the `%MachineState{}` and in the plan
context, not in the GenServer. That is what makes handler-backed
`<invoke>` fully available to a process-less host as of statifier 2.4.0.
[Extending](extending.md) is where you learn to write a handler; this
section is only the three things that differ with no process.

### Declaring the registered types

Two halves, derived from one map so they cannot drift
(ADR-0051 decision 3's "one constructor"):

```elixir
invoke_handlers = %{"myapp:capture" => MyApp.CaptureHandler}

machine_state =
  MachineState.put_invoke_types(
    machine_state,
    Statifier.Invoke.Types.from_handlers(invoke_handlers)
  )
```

`Statifier.Invoke.Types.from_handlers/1`
(`lib/statifier/invoke/types.ex:58-60`) builds the registered-type snapshot
from the dispatch map's own keys, and it is the only such derivation in the
library. The core classifies an `<invoke type>` against the snapshot
(`Statifier.Invoke.Types.registered?/2`,
`lib/statifier/invoke/types.ex:78-80`); the planner dispatches on the map.
An unregistered type raises `error.execution` and starts nothing
(spec 3.12.2).

This is beat 1 of the loop again: `invoke_types` is one of the two fields a
position blob deliberately returns as `nil`
([ADR-0064](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0064-position-blob-drops-the-per-drive-snapshot-fields.md)),
so re-stamp it on **every** load, not once at run creation.

### Answering an invocation

A live session has two doors that take a pid -
`Statifier.Session.done_invocation/3` and `failed_invocation/3`. A
process-less host has no pid to hand them, so it calls the construction
site both doors call through and feeds the result to its next drive:

```elixir
event = Statifier.Invoke.Answer.done(run_id, "inv_3", %{"outcome" => "approved"})
{:ok, machine_state, effects} = Statifier.Interpreter.handle_event(machine_state, event)
```

`Statifier.Invoke.Answer.done/4` (`lib/statifier/invoke/answer.ex:95-101`)
builds `done.invoke.<invoke_id>`;
`Statifier.Invoke.Answer.failed/4` (`lib/statifier/invoke/answer.ex:155-161`)
builds `error.communication.invoke.<invoke_id>` for a permanent failure
after your retries are exhausted
([ADR-0068](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md)).
Both are pure - same arguments, same event, no clock, no id minting - so
re-driving a recovered step rebuilds a byte-identical event.

**Liveness is yours here too.** A session discards an answer for an
invocation the chart already cancelled (spec 6.4.3) and pops its table
entry. You have neither a drain nor a table, so check your own invocation
row before feeding the event in, and drop the row afterwards either way.

### Carrying the caller context

Both builders take an optional `caller_context:`
([ADR-0063](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0063-caller-context-on-external-events-and-durable-timer-effects.md))
and copy it onto the answer unread. The value to pass is the **invoking**
event's, not the reporting call's - the term that rode the external event
whose macrostep executed the `<invoke>`. The core stamps it onto the
`%Statifier.Effect.Invoke{}` it emits, so store it beside your invocation
row when you arm the work:

```elixir
# When the `%Statifier.Effect.Invoke{}` came out of the drive:
#   store_invocation(run_id, invoke.invoke_id, invoke.caller_context)

{invoke_id, caller_context} = load_invocation(run_id, "inv_3")

event =
  Statifier.Invoke.Answer.failed(run_id, invoke_id, [reason: "exhausted", attempts: 5],
    caller_context: caller_context
  )
```

Omitted, it is `nil` - "no context attached", never an error. The full
recipe, including why a *resumed* session cannot help you here, is
[Persistence](persistence.md)'s "Answering an invocation with no session
process".

## Quiescence, and when a position is safe to persist

A position is written **at quiescence**: the macrostep has finished folding
and the internal event queue is empty. That is beat 4, and it is not
advisory.

`Statifier.MachineState.internal_queue_empty?/1`
(`lib/statifier/machine_state.ex:734`) is the predicate. A non-empty queue
means the chart has work it has not done yet; a position written there
would either lose those events or resume mid-macrostep, and both are
wrong. `Statifier.Position.export/1` refuses a non-empty queue outright
(`lib/statifier/position.ex:265-271`), and `Statifier.Session.start_link/2`
refuses to resume one with `{:error, {:resume, :position_not_quiescent}}`
([ADR-0060](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0060-resuming-a-session-from-a-persisted-position.md)),
so a driver that persists a non-quiescent position has written a blob
nothing will take back.

Each advance entry already folds to quiescence before it returns -
`handle_event/2`'s last act is the fold (`lib/statifier/interpreter.ex:476-483`),
and `macrostep/1` *is* the fold (`lib/statifier/interpreter.ex:1100-1107`).
So a driver that persists after a completed advance entry is quiescent by
construction, and a driver that persists between `microstep/1` calls is
not. If you step, fold before you write.

One case used to be the exception and no longer is. A chart reaching a
top-level `<final>` can leave sibling `done.state.*` events queued, which
made a terminated run permanently unpersistable; `exit_interpreter/1` now
discards the remaining internal queue at the end of the exit walk, so
**a `:done` machine_state is quiescent by construction**
(`lib/statifier/machine_state.ex:263-275`). Nothing can dequeue an internal
event once the loop has stopped, so events still queued at termination are
unreachable rather than pending. That rule is what makes "persist the run
as completed" a thing a driver can always do.

Two related refusals worth knowing before you design around them, both
listed in full in [Persistence](persistence.md)'s "Refusals" table:
`:position_not_running` (a `running: false` position has nothing left for a
driver to do with it) and `{:identity_mismatch, expected, actual}` (the
position was saved against a different chart revision - the entire reason
identity is stamped, `lib/statifier/position.ex:105-110`).

## Telemetry: naming your driver

The library emits one telemetry family, `[:statifier, :session, ...]`, and
the `:session` segment names the **logical** SCXML session - the
`_sessionid` a position carries - not the `Statifier.Session` process
(ADR-0067 decision 1). A durably-stepped macrostep is not a different kind
of thing from a process-hosted one, so it does not get a different event
name.

`Statifier.Telemetry` is the caller-agnostic emitter every driver calls,
and every public function on it takes a leading `driver :: atom()`
(`lib/statifier/telemetry.ex:290-296`) that lands on every event's metadata
under the `driver` key:

| Emitter | Emits | Defined at |
|---|---|---|
| `init/6` | `[:statifier, :session, :init]` | `lib/statifier/telemetry.ex:356-364` |
| `halt/4` | `[..., :halt]` | `lib/statifier/telemetry.ex:380-386` |
| `terminate/5` | `[..., :terminate]` | `lib/statifier/telemetry.ex:404-411` |
| `macrostep_start/5` | `[..., :macrostep, :start]` | `lib/statifier/telemetry.ex:439-446` |
| `macrostep_stop/8` | `[..., :macrostep, :stop]` | `lib/statifier/telemetry.ex:472-482` |
| `interpret/4` | `[..., :interpret]` | `lib/statifier/telemetry.ex:515-521` |
| `effect/4` | the 11 `[..., :effect, _]` and 10 `[..., :trace, _]` events | `lib/statifier/telemetry.ex:538-555` |
| `unroutable/4` | `[..., :unroutable]` | `lib/statifier/telemetry.ex:566-572` |

`Statifier.Session.Telemetry` is a thin facade over the same functions with
`driver: :session` pinned; a process-less driver calls `Statifier.Telemetry`
directly and passes its own atom. The 27 event names and their per-event
measurement and metadata shapes are the module's own contract table
(`lib/statifier/telemetry.ex:158-164` for the lifecycle events,
`lib/statifier/telemetry.ex:205-215` for the effect events, and
`lib/statifier/telemetry.ex:226-235` for the trace events) - that is
reference material, and it is not restated here.

Not every driver emits every event, and that is by design
(ADR-0067 decision 3, tabulated at `lib/statifier/telemetry.ex:25-40`):

- `:terminate` names a GenServer callback. A process-less driver has no
  process to terminate and emits none.
- `:interpret` is the ADR-0029 effect-injection seam. Emit it only if your
  driver exposes an equivalent seam; if it does not, emit nothing rather
  than minting a name.
- `:init` marks initialization, not loading. Emit it once per logical run,
  at `initialize/2` - **never** per load, or a run stepped a thousand
  times reports a thousand initializations.
- Everything else - `:halt`, the macrostep span, the effect and trace
  events, `:unroutable` - is driver-uniform.

**A span never crosses a persist boundary.** `macrostep_start/5` and
`macrostep_stop/8` must be emitted within one driver call: the span ref is
node- and VM-local (ADR-0067 decision 5). If your driver persists between
the two halves, you have leaked a span.

**Pick your driver atom once and freeze it.** It reaches backends as an
attribute a real consumer will build dashboards on, so changing it later is
a breaking change to them. `statifier_persistence` 0.5.x picked
`:persistence` and froze it, and its
[docs/telemetry.md](https://github.com/riddler/statifier_persistence/blob/main/docs/telemetry.md)
is the worked example of a driver doing everything in this section: the
per-event applicability table at its emit sites, the `session_id` read out
of the decoded datamodel rather than looked up, and the rule that its own
storage vocabulary (`run_id`, locks, adapter calls) travels on a *second*
family, `[:statifier_persistence, ...]`, rather than being smuggled onto
this one (ADR-0067 decisions 4 and 6). Follow that split: this family
describes the chart, your own family describes your storage.

## What you do not have to build

Everything above is a real amount of work, and most of it has been done
once already:

- **`statifier_persistence`** is this loop as a package: the storage-adapter
  behaviour with the identity guard, the run lifecycle, the stepper, and
  the Ecto adapter. It emits family one with `driver: :persistence` and its
  own family two.
- **`statifier_oban`** drives that loop from Oban jobs: durable delayed
  sends and asynchronous invoke execution, with the keying and liveness
  rules from [Durable timers](durable-timers.md) already implemented.
- **`opentelemetry_statifier`** turns the telemetry above into spans, and
  because the driver atom is metadata rather than a name, a durable run and
  a session-hosted run land in the same span vocabulary with one attribute
  telling them apart.

Write your own driver when your host's transaction, locking, or scheduling
story is genuinely not theirs. Otherwise, reach for those three and spend
the time on your chart.
