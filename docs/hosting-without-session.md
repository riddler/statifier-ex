# How to host the pure core without `Statifier.Session`

**Read this to:** drive a chart from your own job or handler, with no
`Statifier.Session` process.
**Short version:** the pure core is a fold. Give `Statifier.Interpreter` a
`%Statifier.MachineState{}` and an event. It returns a new
`%MachineState{}` and a list of effects. You perform the effects, and you
persist the position at quiescence.

`Statifier.Session` is one driver of a chart. It is not the definition of a
chart. A durable host steps a chart from a job, persists the result, and
stays idle until the next job wakes it. This library supports such a host,
and this guide is its contract.

Decision: [ADR-0067](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md) decision 1.

This guide covers:

- what your driver owes the interpreter for each effect
- how timers and `<invoke>` handlers work with no process to call
- when a position is safe to write down
- how to emit the same telemetry as a session-hosted execution

Read these pages with this guide:

- [Persistence](persistence.md): the identity hazard, the position blob,
  what a host must persist, and the process-less invoke answer recipe.
- [Durable timers](durable-timers.md): Route B is the process-less half of
  delayed sends. It includes the store keying and the delivery-time liveness
  check.
- [Extending](extending.md): how to write and register `<invoke>` handlers,
  and how to register `<send>` types.
- [Observability](observability.md) and [OpenTelemetry](opentelemetry.md):
  what the trace effects carry and what the bridge does with them.

## What you take on, and what you get

A session process does six jobs. If you drive the core yourself, you do all
six.

| Job | `Statifier.Session` does it by | You do it by |
|---|---|---|
| Holding the position | keeping `%MachineState{}` in process state | persisting a position blob between drives ([Persistence](persistence.md)) |
| Advancing the chart | calling an `Interpreter` entry from a callback | calling the same entry from your job/handler |
| Acting on effects | planning then performing them | planning then performing them (the plan half is public, see below) |
| Timers | `Process.send_after/3` and a per-session timer table | your own durable scheduler ([Durable timers](durable-timers.md) Route B) |
| `<invoke>` lifecycle | an in-memory invocation table and two answer doors | your own invocation rows and `Statifier.Invoke.Answer` |
| Telemetry | emitting through `Statifier.Telemetry` with `driver: :session` | emitting through the same module with your own driver atom |

In exchange, an execution survives node death, a step is a database
transaction, and the progress of a chart is a row instead of a process.
`statifier_persistence` is this driver, built once so most hosts do not have
to build it. See "What you do not have to build" at the end.

## The loop

Every process-less drive has the same four steps:

1. **Load.** Decode the position against the recompiled chart, and re-stamp
   the three per-drive snapshot fields.
2. **Advance.** Call one `Interpreter` entry with an event (or none).
3. **Execute.** Plan the returned effects into instructions and perform
   them.
4. **Persist.** Write the new position back, at quiescence.

**Step 1.** The reference text is `Statifier.Interpreter`'s "Rehydrating a
position" section (`lib/statifier/interpreter.ex:43-92`). In short:

- `Statifier.Position.from_binary/2` (`lib/statifier/position.ex:161-167`)
  checks the format version and chart identity for you.
- It returns `routes`, `invoke_types` and `send_types` as `nil` on purpose.
- Re-stamp all three before the first advance:
  - `Statifier.MachineState.put_routes/2` (`lib/statifier/machine_state.ex:872-874`)
  - `put_invoke_types/2` (`lib/statifier/machine_state.ex:881-883`)
  - `put_send_types/2` (`lib/statifier/machine_state.ex:891-893`)
- `send_types` is the registered `<send type>` set. Build it from your
  `%{type_string => module}` map with `Statifier.Send.Types.from_send_types/1`.
  With no send type registered it is `nil`, which is what
  `from_send_types/1` returns for an empty map.

Decision: [ADR-0069](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0069-host-registered-send-types.md).

**Step 2.** A driver can use any of six entries. They all take a
`%MachineState{}`, trust it structurally, and keep no state outside that
struct:

| Entry | Use it for | Defined at |
|---|---|---|
| `Statifier.Interpreter.initialize/2` | the execution's very first drive, once ever | `lib/statifier/interpreter.ex:261-263` |
| `Statifier.Interpreter.handle_event/2` | an external event: a fired timer, an invoke answer, a host command | `lib/statifier/interpreter.ex:485-489` |
| `Statifier.Interpreter.deliver_internal/5` | an event routed to `#_internal` | `lib/statifier/interpreter.ex:547-557` |
| `Statifier.Interpreter.cancel/1` | Appendix D's `cancel`: stop the chart | `lib/statifier/interpreter.ex:929-933` |
| `Statifier.Interpreter.macrostep/1` | fold an already-queued position to quiescence | `lib/statifier/interpreter.ex:1100-1107` |
| `Statifier.Interpreter.microstep/1` | one round at a time, for a step debugger | `lib/statifier/interpreter.ex:1014-1031` |

`handle_event/2` returns `{:ok, machine_state, effects}` or
`{:error, :not_running}`. The `running` guard is the loop condition of
Appendix D. A chart that has already terminated refuses the event and does
not consume it (`lib/statifier/interpreter.ex:485-487`).

### A minimal driver, end to end

This is the smallest complete driver. It plans the effects and performs the
instructions it understands. It re-drives the events the plan enqueued, and
it records the timer rows and logs that it owes the outside world. The chart
arms a delayed send and raises an immediate self-send. It terminates when
the timer's event comes back on a second drive.

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

The test `test/statifier/hosting_without_session_test.exs` pins the module
and both drives. It holds the same chart and the same code. If one changes,
change both.

This example has two limits:

- It holds the position in a variable and does not persist it (steps 1 and 4
  are in [Persistence](persistence.md)).
- It registers no `<invoke>` handlers.

Add both and it is a real durable driver.

## The driver contract, effect by effect

`Statifier.Effect` holds the whole vocabulary in one module: eleven core
effects and ten trace effects, as one `@type t()` union
(`lib/statifier/effect.ex:121-149`).

- The table at `lib/statifier/effect.ex:23-45` names the interpreter
  function that produces each effect.
- Every effect is a `{tag, payload_struct}` two-tuple.
- `Statifier.Effect.trace?/1` (`lib/statifier/effect.ex:157-159`) is the one
  match that separates trace effects from core effects.
- Trace effects are ordinary members of the same list, in the same order.
  There is no side channel to keep in sync (`lib/statifier/effect.ex:67-71`).

The table lists what a driver owes each effect. If you skip an obligation,
the chart behaves wrongly or an author-visible obligation is unmet.

| Effect | Payload | What a driver owes it |
|---|---|---|
| `:send` | `Statifier.Effect.Send` (`lib/statifier/effect/send.ex:49-74`) | Deliver the event to the resolved target. A `<send>` with no `target` is a self-send and comes back as the next external event of this execution. `#_internal` goes through `deliver_internal/5`. Your driver must route a session, parent or invoke target. An unsupported type or unparseable target is `error.execution` on the internal queue of the sender |
| `:send_delayed` | `Statifier.Effect.SendDelayed` (`lib/statifier/effect/send_delayed.ex:42-57`) | Store a durable timer row and arm your scheduler. See "Timers" below |
| `:cancel` | `Statifier.Effect.Cancel` (`lib/statifier/effect/cancel.ex:38-48`) | Cancel every stored row under that `send_id`, in your store. A cancel that matches nothing is a no-op and not an error |
| `:invoke` | `Statifier.Effect.Invoke` (`lib/statifier/effect/invoke.ex:62-76`) | Start the invocation through its registered handler, and record an invocation row of your own (id, type, and the `caller_context` the core stamped) |
| `:cancel_invoke` | `Statifier.Effect.CancelInvoke` (`lib/statifier/effect/cancel_invoke.ex:45`) | Stop that invocation through its handler and drop your row. An unknown id is a silent no-op |
| `:autoforward` | `Statifier.Effect.Autoforward` (`lib/statifier/effect/autoforward.ex:36`) | Forward the carried event to that invocation **unmodified** (spec 6.4.2). A miss is a silent no-op |
| `:done` | `Statifier.Effect.Done` (`lib/statifier/effect/done.ex:33-42`) | Mark the execution terminated. `exit_interpreter/1` emits it, and nothing advances after it. Record `donedata` and `donedata_error` together. A failed `<donedata>` resolution and a bare final both leave `donedata: :undefined`, and only `donedata_error` tells them apart (ADR-0021's 2026-09-02 note) |
| `:budget_exhausted` | `Statifier.Effect.BudgetExhausted` (`lib/statifier/effect/budget_exhausted.ex:38`) | Mark the execution halted on the macrostep-round budget. The core is still `running` and you can still cancel it. Do not treat it as `:done` |
| `:log` | `Statifier.Effect.Log` (`lib/statifier/effect/log.ex:24`) | Write it wherever your host writes `<log>`. Nothing in the chart depends on it |
| `:datamodel_change` | `Statifier.Effect.DatamodelChange` (`lib/statifier/effect/datamodel_change.ex:60-72`) | Nothing is owed. The write already happened in the `%MachineState{}` you received. This effect is for observers |
| `:datamodel_init` | `Statifier.Effect.DatamodelInit` (`lib/statifier/effect/datamodel_init.ex:38`) | Nothing is owed, for the same reason. This effect is the starting baseline, for observers |
| `:trace` (ten) | `Statifier.Effect.Trace.*` (`lib/statifier/effect.ex:135-146`) | Nothing is owed. Forward them to observers or drop them. The core produces them only when the position carries `trace: true` |

Three of these effects need durable state on your side of the boundary:
`:send_delayed`, `:invoke`, and `:cancel_invoke`.

### Do not re-derive the routing: `Statifier.Session.Effects.plan/2`

The rules above already exist as pure code that a process-less driver can
call. They define which `<send>` target means what, when an unsupported type
is `error.execution` and not `error.communication`, and which handler a
`:cancel_invoke` dispatches to.

`Statifier.Session.Effects.plan/2` (`lib/statifier/session/effects.ex:196-200`):

- takes the effect list and a plain map
- returns an ordered list of instructions (`lib/statifier/session/effects.ex:165-179`)
- touches no process and holds no state
- is public so that an embedder can give it effects (`lib/statifier/session/effects.ex:15-23`)

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
your own invocation rows. It lets a `:cancel_invoke` or an `:autoforward`
reach the handler that started the invocation. Decision: ADR-0051 decision 6.

The instructions that `plan/2` returns, and how a process-less host performs
each one:

| Instruction | Perform it by |
|---|---|
| `{:notify, effect}` | one per effect, in the order of the core: give it to your observers, your telemetry, or nothing |
| `{:enqueue_event, event}` | feed it to this execution's next drive (a self-send) |
| `{:deliver, route, event, effect}` | route it: `:internal` goes through `deliver_internal/5`, and your addressing scheme handles all other routes |
| `{:raise, kind, name, origin, opts}` | raise that platform event on this execution's own internal queue, through `deliver_internal/5` |
| `{:schedule, send_id, delay_ms, route, event, effect}` | write the durable timer row and arm your scheduler |
| `{:cancel_timers, send_id}` | delete every row under that `send_id` |
| `{:start_child, invoke, effect}` | start the child chart for a `type="scxml"` invocation |
| `{:forward, invoke_id, event}` | forward the event to that invocation, unmodified |
| `{:stop_child, invoke_id}` | stop that invocation; unknown id is a no-op |
| `{:handler, module, term}` | the handler's own instruction, opaque to the library: perform it yourself |
| `{:unroutable, effect}` | you could not route it; report it (see "Telemetry" below) |
| `{:halt, reason}` | `:done` or `:budget_exhausted`: mark the execution terminated or halted |

Call `plan/2` and do not re-implement the table. One implementation makes
"the durable path behaves like the session path" a structural fact and not a
review obligation. ADR-0067 decision 2 gives the same reason for telemetry.

## Timers: scheduling and cancelling delayed sends

A `%SendDelayed{}` is a request to deliver an event after `delay_ms`
milliseconds. The library writes no wall-clock instant, because it reads no
clock. You compute and keep the deadline. A durable scheduler consumes the
public effect vocabulary and has no seam of its own. The per-execution
`ordinal` identifies a stored row uniquely.

Decisions:
[ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md)
decision 2 (no clock),
[ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md)
(public vocabulary),
[ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md)
(`ordinal`).

[Durable timers](durable-timers.md) is the full guide. Its "Route B: a
process-less host" section fixes four rules, so you do not have to decide
them:

1. **Two keys.** Cancellation uses the key `{session scope, send_id}` and
   can match several rows. Deduplication uses the counters of the stored
   `%SendDelayed{}` plus `ordinal`.
2. **Scope is mandatory.** `send_counter` restarts at 0 for every
   `%MachineState{}`, so `send_1` from two executions collides unless your
   store keeps them apart. Use the `_sessionid` of the execution.
3. **Take attribution from the stored row.** Never compute it at fire time.
   The counters were stamped when the send was scheduled.
4. **Check liveness at delivery.** Spec 6.2 requires that the host discard a
   message if the session terminated before the delay elapsed. A durable
   scheduler outlives the process that would do this. A process-less host
   must check its own persisted terminated or halted state before it feeds a
   fired event into the next drive.

A cancel is the mirror image. `%Cancel{}` carries the same `ordinal` field
for the same reason. Two cancels of one `send_id` from two `<foreach>`
iterations are distinct rows, and your store must not collapse them.

## Invoke handlers with no session process

Handlers register per session. This stays true when the session process is
not the only driver: the registration lives on the `%MachineState{}` and in
the plan context, not in the GenServer. Since statifier 2.4.0, this makes
handler-backed `<invoke>` fully available to a process-less host.
[Extending](extending.md) explains how to write a handler. Three things
differ when there is no process.

Decision: [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md).

### Declaring the registered types

Two halves come from one map, so they cannot drift (one constructor,
ADR-0051 decision 3):

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
from the keys of the dispatch map. It is the only such derivation in the
library. The core classifies an `<invoke type>` against the snapshot
(`Statifier.Invoke.Types.registered?/2`,
`lib/statifier/invoke/types.ex:78-80`). The planner dispatches on the map.
An unregistered type raises `error.execution` and starts nothing
(spec 3.12.2).

This is step 1 of the loop again. `invoke_types` is one of the three fields
that a position blob returns as `nil` on purpose. Re-stamp it on every load,
not only when you create the execution.

Decision: [ADR-0064](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0064-position-blob-drops-the-per-drive-snapshot-fields.md).

### Answering an invocation

A live session has two functions that take a pid:
`Statifier.Session.done_invocation/3` and `failed_invocation/3`. A
process-less host has no pid to give them. Instead, call the construction
site that both functions use, and feed the result to the next drive:

```elixir
event = Statifier.Invoke.Answer.done(run_id, "inv_3", %{"outcome" => "approved"})
{:ok, machine_state, effects} = Statifier.Interpreter.handle_event(machine_state, event)
```

`Statifier.Invoke.Answer.done/4` (`lib/statifier/invoke/answer.ex:95-101`)
builds `done.invoke.<invoke_id>`.
`Statifier.Invoke.Answer.failed/4` (`lib/statifier/invoke/answer.ex:155-161`)
builds `error.communication.invoke.<invoke_id>` for a permanent failure
after your retries are exhausted.

Both are pure: the same arguments give the same event, with no clock and no
id minting. A re-driven recovered step therefore rebuilds a byte-identical
event.

Decision: [ADR-0068](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md).

**Check liveness.** A session discards an answer for an invocation that the
chart already cancelled (spec 6.4.3) and pops its table entry. You have no
drain and no table. Check your own invocation row before you feed the event
in, and drop the row afterwards in either case.

### Carrying the caller context

Both builders take an optional `caller_context:` and copy it onto the answer
unread. Pass the value of the invoking event, not the value of the reporting
call. This is the term on the external event whose macrostep executed the
`<invoke>`. The core stamps it onto the `%Statifier.Effect.Invoke{}` that it
emits, so store it beside your invocation row when you arm the work.

Decision: [ADR-0063](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0063-caller-context-on-external-events-and-durable-timer-effects.md).

```elixir
# When the `%Statifier.Effect.Invoke{}` came out of the drive:
#   store_invocation(run_id, invoke.invoke_id, invoke.caller_context)

{invoke_id, caller_context} = load_invocation(run_id, "inv_3")

event =
  Statifier.Invoke.Answer.failed(run_id, invoke_id, [reason: "exhausted", attempts: 5],
    caller_context: caller_context
  )
```

If you omit it, the value is `nil`, which means "no context attached" and
is never an error. [Persistence](persistence.md) gives the full recipe in
"Answering an invocation with no session process". It also explains why a
resumed session cannot help you here.

## Quiescence, and when a position is safe to persist

Write a position at quiescence: the macrostep has finished folding and the
internal event queue is empty. This is step 4, and it is a requirement.

`Statifier.MachineState.internal_queue_empty?/1`
(`lib/statifier/machine_state.ex:734`) is the predicate. A non-empty queue
means the chart has work left to do. A position written then either loses
those events or resumes mid-macrostep, and both are wrong.

- `Statifier.Position.export/1` refuses a non-empty queue
  (`lib/statifier/position.ex:265-271`).
- `Statifier.Session.start_link/2` refuses to resume one with
  `{:error, {:resume, :position_not_quiescent}}`.
- A driver that persists a non-quiescent position writes a blob that
  nothing can read back.

Decision: [ADR-0060](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0060-resuming-a-session-from-a-persisted-position.md).

Each advance entry folds to quiescence before it returns.
`handle_event/2` ends with the fold (`lib/statifier/interpreter.ex:476-483`),
and `macrostep/1` is the fold (`lib/statifier/interpreter.ex:1100-1107`).
A driver that persists after a completed advance entry is quiescent by
construction. A driver that persists between `microstep/1` calls is not. If
you step, fold before you write.

A terminated execution is also quiescent. A chart that reaches a top-level
`<final>` can leave sibling `done.state.*` events queued. That used to make a
terminated execution permanently unpersistable. `exit_interpreter/1` now
discards the remaining internal queue at the end of the exit walk, so a
`:done` machine_state is quiescent by construction
(`lib/statifier/machine_state.ex:263-275`). Those queued events are
unreachable, not pending: nothing can dequeue an internal event after the
loop stops. A driver can always persist an execution as completed.

[Persistence](persistence.md)'s "Refusals" table lists two related refusals:

- `:position_not_running`: a `running: false` position has nothing left for
  a driver to do with it.
- `{:identity_mismatch, expected, actual}`: the position was saved against a
  different chart revision. This is the entire reason the library stamps
  identity (`lib/statifier/position.ex:105-110`).

## Telemetry: naming your driver

The library emits one telemetry family, `[:statifier, :session, ...]`. The
`:session` segment names the logical SCXML session (the `_sessionid` that a
position carries). It does not name the `Statifier.Session` process. A
durably stepped macrostep is the same kind of thing as a process-hosted
one, so it has the same event name. Decision: ADR-0067 decision 1.

`Statifier.Telemetry` is the caller-agnostic emitter that every driver
calls. Every public function on it takes a leading `driver :: atom()`
(`lib/statifier/telemetry.ex:290-296`). The value lands on the metadata of
every event under the `driver` key:

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
`driver: :session` fixed. A process-less driver calls `Statifier.Telemetry`
directly and passes its own atom. The contract table of the module lists the
27 event names and the measurement and metadata shapes of each event:

- lifecycle events: `lib/statifier/telemetry.ex:158-164`
- effect events: `lib/statifier/telemetry.ex:205-215`
- trace events: `lib/statifier/telemetry.ex:226-235`

A driver does not emit every event. This is by design
(ADR-0067 decision 3, tabulated at `lib/statifier/telemetry.ex:25-40`):

- `:terminate` names a GenServer callback. A process-less driver has no
  process to terminate and emits none.
- `:interpret` is the ADR-0029 effect-injection seam. Emit it only if your
  driver exposes an equivalent seam. If it does not, emit nothing and do not
  invent a name.
- `:init` marks initialization, not loading. Emit it once per logical
  execution, at `initialize/2`. Never emit it per load: an execution
  stepped a thousand times would report a thousand initializations.
- All other events are the same for every driver: `:halt`, the macrostep
  span, the effect and trace events, and `:unroutable`.

**Span.** A span must not cross a persist boundary. Emit `macrostep_start/5`
and `macrostep_stop/8` within one driver call, because the span ref is local
to the node and VM. If your driver persists between the two halves, you have
leaked a span. Decision: ADR-0067 decision 5.

**Driver atom.** Pick it once and do not change it. It reaches backends as
an attribute, and consumers build dashboards on it. A later change breaks
those dashboards.

**Two families.** This family describes the chart. Your own family describes
your storage. `statifier_persistence` follows this split: its storage
vocabulary (`run_id`, locks, adapter calls) travels on a second family,
`[:statifier_persistence, ...]`. Decisions: ADR-0067 decisions 4 and 6.

**Worked example.** `statifier_persistence` 0.5.x picked `:persistence` and
froze it. Its
[docs/telemetry.md](https://github.com/riddler/statifier_persistence/blob/main/docs/telemetry.md)
shows a driver that does everything in this section. It has a per-event
applicability table at its emit sites, and it reads the `session_id` from
the decoded datamodel and does not look it up.

## What you do not have to build

These packages already do most of the work above:

- **`statifier_persistence`** is this loop as a package. It has the
  storage-adapter behaviour with the identity guard, the execution
  lifecycle, the stepper, and the Ecto adapter. It emits family one with
  `driver: :persistence` and its own family two.
- **`statifier_oban`** drives that loop from Oban jobs. It provides durable
  delayed sends and asynchronous invoke execution, and it implements the
  keying and liveness rules from [Durable timers](durable-timers.md).
- **`opentelemetry_statifier`** turns the telemetry above into spans. The
  driver atom is metadata and not part of the name, so a durable execution
  and a session-hosted execution use the same span vocabulary. One attribute
  tells them apart.

Write your own driver only if the transaction, locking, or scheduling model
of your host does not fit these packages. Otherwise, use them and spend the
time on your chart.