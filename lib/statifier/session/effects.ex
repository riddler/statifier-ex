defmodule Statifier.Session.Effects do
  @moduledoc """
  Turns the effect list the pure core returns into an ordered list of
  instructions for `Statifier.Session` to perform (ADR-0003). Deciding is
  here, where it is a pure function of the effect list; performing is there,
  where the process is.

  Every effect produces a `{:notify, effect}` instruction in its original
  position, so a subscriber sees the whole stream in order - trace effects
  included, since they are ordinary list members and not a side channel.
  Effects that also mean something to the session emit their action
  immediately after their own `:notify`.

  ## `<send>` routing

  Every `<send>`/`<send_delayed>` effect is planned in this order (6.2.4,
  6.2.5, C.1). Steps 1 and 2 are a boundary check, not the primary
  enforcement: ADR-0047 decision 4 keeps them because
  `Statifier.Session.interpret/2` is public (ADR-0029) and an embedder can
  hand in an effect the core itself never produced, but an effect the core
  *did* produce never reaches these two arms - the core already rejected an
  invalid target or unsupported type in `Statifier.Machine.Content.Send`
  before any `{:send, _}`/`{:send_delayed, _}` effect was built.

  1. An unsupported `type` (`Statifier.Send.Target.supported_type?/1`) ->
     `{:raise, :platform, "error.execution", ...}` on the sender's own
     internal queue. No delivery, no timer.
  2. An unparseable `target` (`Statifier.Send.Target.parse/1` returns
     `{:invalid, _}`) -> the same `error.execution` (6.2.4's "not supported
     or invalid").
  3. `:self` (no `target`) -> `{:enqueue_event, event}`, delivered straight
     to the sending session's own external queue.
  4. `:internal` (`#_internal`/`_internal`) -> `{:deliver, :internal, event,
     effect}`, resolved by `Statifier.Session` through
     `Statifier.Interpreter.deliver_internal/5` (ADR-0039).
  5. `{:session, _}`, `:parent`, `{:invoke, _}` -> `{:deliver, route, event,
     effect}`; `Statifier.Session` resolves the route (self-addressing needs
     no registry, decision 10; everything else is `error.communication`
     until a later bead adds one).

  A delayed send takes the same route through `{:schedule, send_id,
  delay_ms, route, event, effect}` instead of `{:enqueue_event, _}` /
  `{:deliver, _, _, _}` - the type/target checks above still run at *plan*
  time (6.2.3: arguments are evaluated when `<send>` is evaluated, not when
  the message is dispatched), but the route itself is only resolved when the
  timer fires.

  ## `<invoke>` routing

  `plan_invoke/3` checks `type` first, mirroring `<send>`'s own order
  (6.2.5's unsupported-`type` check ahead of target resolution): an
  unregistered `type` (`Statifier.Invoke.Types.registered?/2`, judged
  against the plan context's `:invoke_types` snapshot - ADR-0051) plans
  `{:raise, :platform, "error.execution", {:invoke, state_index,
  invoke_index}, []}` and nothing else - 3.12.2 puts an unregistered `type`
  in `error.execution`'s class ("errors internal to the execution of the
  document"), the same class `<send>`'s own unsupported-type check uses,
  because no communication is attempted at all. A registered `type` looks
  up its handler module in the plan context's `:invoke_handlers` map
  (`Map.get/3`, defaulting to `Statifier.Invoke.Handler.Scxml` - the
  built-in handler is just the default map entry, so no branch here names
  `scxml` specially, ADR-0051 decision 4) and splices `module.start/2`'s
  own returned instructions into the plan. The built-in handler's `start/2`
  returns `{:start_child, invoke, effect}` unchanged from what this module
  used to produce directly - `Statifier.Session` resolves the source, seeds
  the child's datamodel, and starts it (ADR-0027 decision 3, ADR-0038).

  ## The plan context

  `plan/2`'s second argument is a plain map, not a bare session id:
  `%{session_id: String.t(), invoke_types: Statifier.Invoke.Types.t() |
  nil, invoke_handlers: %{String.t() => module()}, invocation_types:
  %{String.t() => String.t()}}` (ADR-0051 decisions 2, 4, and 6).
  `session_id` is what every `plan_send/3` / `plan_send_delayed/3` call used
  to receive directly; `invoke_types` is the caller-declared registered set
  `plan_invoke/3` judges against, read off the same `%MachineState{}` the
  core was stamped with, so the planner's answer and the core's
  `maybe_record_active_invocation/5` answer cannot drift (ADR-0047 decision
  4); `invoke_handlers` is the per-session handler dispatch map
  `plan_invoke/3` looks a registered type's module up in, and is also
  exactly the `ctx` argument every `Statifier.Invoke.Handler` planning
  callback receives; `invocation_types` is the *live* `invoke_id => type`
  snapshot `plan_one/2`'s `:cancel_invoke`/`:autoforward` arms look a
  tracked invocation's own type up in, before doing the same
  `invoke_handlers` dispatch `plan_invoke/3` does at start time (decision
  6). Both `Statifier.Session` and `Statifier.Replay` build this map from
  the `%MachineState{}`/session state they already hold before calling
  `plan/2`, deriving `invoke_types`, `invoke_handlers`, and
  `invocation_types` from the same source so none of the three can diverge
  (ADR-0051 decision 3's "one constructor").

  `:autoforward` and `:cancel_invoke` route through the owning invocation's
  own handler (ADR-0051 decision 6), the same dispatch `plan_invoke/3` uses
  for `start/2`: the plan context's `:invocation_types` map (built by
  `Statifier.Session`/`Statifier.Replay` from the live invocation table,
  `Statifier.Session.Invocations.types/1`) answers `invoke_id`'s own `type`,
  looked up in `:invoke_handlers` the same way, defaulting to
  `Statifier.Invoke.Handler.Scxml` when the map answers nothing for
  `invoke_id`. Every entry `Statifier.Session` writes records `invoke.type`
  unconditionally, a built-in `scxml` invocation's own literal `"scxml"`
  included - that is what lets an `invoke_handlers` map explicitly
  overriding `"scxml"` be honored on cancel/forward exactly as it already is
  on start - so the lookup misses only for an invocation that is not live at
  all (a `cancel_invoke`/`autoforward` naming a dead or never-started
  invocation), or for an entry carrying no `type` key, which
  `Statifier.Session.Invocations.types/1` leaves out of its projection
  entirely rather than mapping to `nil`. The built-in handler's `cancel/2`
  and `forward/3` return exactly the `{:stop_child, invoke_id}`/`{:forward,
  invoke_id, event}` instructions this module used to emit directly, so
  dispatching through it changes nothing observable for `type=scxml`.

  `:autoforward`'s dispatch carries no type or target check of its own
  beyond the handler lookup, since the effect is the core's own decision
  about an invocation this session started, not a `<send>` with
  author-written attributes. The built-in handler's `{:forward, invoke_id,
  event}` instruction has `Statifier.Session` look `invoke_id` up in its
  invocation table and forward `event` unmodified (6.4.2's "All the fields
  specified in 5.10.1 ... MUST have the same values in the forwarded
  copy"); a miss, or a handler-backed entry with no pid to deliver to, is a
  silent no-op, not an error (6.4.3's MUST-ignore for a cancelled
  invocation).

  `:cancel_invoke`'s dispatch is unconditional for the same reason
  `:autoforward`'s is: this is the core's own reaction to a state exiting
  while one of its `<invoke>`s is still live, not an author-addressed
  element. The built-in handler's `{:stop_child, invoke_id}` instruction has
  `Statifier.Session` pop the table entry and, when it held a pid, demonitor
  and cancel the child (6.4.3); a miss, or an entry with no pid, is a
  silent no-op - the invocation having already been popped by its own
  `:DOWN` or a prior cancel, or never having had a child process at all.
  """

  alias Statifier.{Effect, Event}
  alias Statifier.Effect.{Autoforward, Cancel, CancelInvoke, Invoke, Send, SendDelayed}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event.Cause
  alias Statifier.Invoke.Handler.Scxml, as: ScxmlHandler
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Send.Target

  @typedoc "Which internal-queue writer `{:raise, ...}` should use - `Statifier.Interpreter.deliver_internal/5`'s own `kind`."
  @type raise_kind :: :internal | :platform

  @typedoc """
  The pure fold's context (ADR-0051 decisions 2, 4, and 6) - see the
  moduledoc's "The plan context" section, and
  `Statifier.Invoke.Handler.t:ctx/0`, which this is (plus `invocation_types`,
  a key no handler callback reads - see its own doc below). `session_id` is
  the sending session's own id (spec 5.10's `_sessionid`); `invoke_types` is
  the caller-declared registered-type snapshot `plan_invoke/3` judges
  against, or `nil` for "no declaration made"; `invoke_handlers` is the
  per-session `<invoke type> => module` dispatch map `plan_invoke/3` looks
  a registered type's handler up in; `invocation_types` is the live
  `invoke_id => type` snapshot `plan_one/2`'s `:cancel_invoke`/
  `:autoforward` arms judge against before doing the same
  `invoke_handlers` dispatch.
  """
  @type context :: %{
          session_id: String.t(),
          invoke_types: InvokeTypes.t() | nil,
          invoke_handlers: %{String.t() => module()},
          invocation_types: %{String.t() => String.t()}
        }

  @typedoc "One instruction for `Statifier.Session` to perform."
  @type instruction ::
          {:notify, Effect.t()}
          | {:enqueue_event, Event.t()}
          | {:deliver, Target.route(), Event.t(), Effect.t()}
          | {:raise, raise_kind(), name :: String.t(), Cause.origin(), keyword()}
          | {:schedule, send_id :: String.t() | nil, delay_ms :: non_neg_integer(),
             Target.route(), Event.t(), Effect.t()}
          | {:cancel_timers, send_id :: String.t()}
          | {:start_child, Invoke.t(), Effect.t()}
          | {:forward, invoke_id :: String.t(), Event.t()}
          | {:stop_child, invoke_id :: String.t()}
          | {:handler, module(), term()}
          | {:unroutable, Effect.t()}
          | {:halt, :done | :budget_exhausted}

  @doc """
  Plans `effects`, the core's own order preserved, into the instructions
  `Statifier.Session` performs. `context` is the plan context (`t:context/0`
  - see the moduledoc's "The plan context" section): `session_id` is the
  sending session's own id (spec 5.10's `_sessionid`), needed to build a
  delivered event's `origin`; `invoke_types` is the registered-type
  snapshot `plan_invoke/3` judges against, `invoke_handlers` is the
  dispatch map it looks a registered type's handler module up in, and
  `invocation_types` is the live snapshot `:cancel_invoke`/`:autoforward`
  judge a tracked invocation's own type against before the same dispatch.
  `:log`,
  `:datamodel_change`,
  `:datamodel_init`, and `:trace` effects plan to nothing but their own
  `{:notify, effect}`.
  """
  @spec plan(effects :: [Effect.t()], context :: context()) :: [instruction()]
  def plan(effects, %{session_id: session_id} = context)
      when is_list(effects) and is_binary(session_id) do
    Enum.flat_map(effects, &plan_one(&1, context))
  end

  @spec plan_one(effect :: Effect.t(), context :: context()) :: [instruction()]
  defp plan_one({:send, %Send{} = send} = effect, context) do
    [{:notify, effect} | plan_send(send, effect, context)]
  end

  defp plan_one({:send_delayed, %SendDelayed{} = send} = effect, context) do
    [{:notify, effect} | plan_send_delayed(send, effect, context)]
  end

  defp plan_one({:cancel, %Cancel{send_id: send_id}} = effect, _context) do
    [{:notify, effect}, {:cancel_timers, send_id}]
  end

  defp plan_one({:invoke, %Invoke{} = invoke} = effect, context) do
    [{:notify, effect} | plan_invoke(invoke, effect, context)]
  end

  defp plan_one({:cancel_invoke, %CancelInvoke{invoke_id: invoke_id}} = effect, context) do
    {:ok, instructions} = handler_for(invoke_id, context).cancel(invoke_id, context)
    [{:notify, effect} | instructions]
  end

  defp plan_one({:autoforward, %Autoforward{} = af} = effect, context) do
    {:ok, instructions} =
      handler_for(af.invoke_id, context).forward(af.invoke_id, af.event, context)

    [{:notify, effect} | instructions]
  end

  defp plan_one({:done, _done} = effect, _context) do
    [{:notify, effect}, {:halt, :done}]
  end

  defp plan_one({:budget_exhausted, _budget_exhausted} = effect, _context) do
    [{:notify, effect}, {:halt, :budget_exhausted}]
  end

  defp plan_one({:log, _log} = effect, _context), do: [{:notify, effect}]
  defp plan_one({:datamodel_change, _change} = effect, _context), do: [{:notify, effect}]
  defp plan_one({:datamodel_init, _init} = effect, _context), do: [{:notify, effect}]
  defp plan_one({:trace, _payload} = effect, _context), do: [{:notify, effect}]

  # An immediate `<send>`'s own routing (see moduledoc's numbered list).
  @spec plan_send(send :: Send.t(), effect :: Effect.t(), context :: context()) :: [
          instruction()
        ]
  defp plan_send(send, effect, %{session_id: session_id}) do
    if Target.supported_type?(send.type) do
      case Target.parse(send.target) do
        {:invalid, _target} ->
          [execution_error(send)]

        :self ->
          [{:enqueue_event, delivered_event(send, session_id)}]

        :internal ->
          [{:deliver, :internal, internal_event(send), effect}]

        route ->
          [{:deliver, route, delivered_event(send, session_id), effect}]
      end
    else
      [execution_error(send)]
    end
  end

  # A `<send delay="...">`'s own routing - the same type/target checks as
  # `plan_send/3`, run at plan (evaluation) time per 6.2.3, but the resolved
  # route travels with the `{:schedule, ...}` instruction instead of
  # resolving now, since the destination is only reached once the timer
  # fires.
  @spec plan_send_delayed(send :: SendDelayed.t(), effect :: Effect.t(), context :: context()) ::
          [instruction()]
  defp plan_send_delayed(send, effect, %{session_id: session_id}) do
    if Target.supported_type?(send.type) do
      case Target.parse(send.target) do
        {:invalid, _target} ->
          [execution_error(send)]

        :internal ->
          [{:schedule, send.send_id, send.delay_ms, :internal, internal_event(send), effect}]

        route ->
          [
            {:schedule, send.send_id, send.delay_ms, route, delivered_event(send, session_id),
             effect}
          ]
      end
    else
      [execution_error(send)]
    end
  end

  # An `<invoke>`'s own routing (see moduledoc's "`<invoke>` routing"
  # section). Unlike `plan_send/3`, there is no target to check - `<invoke>`
  # has none - so `type` is the only gate, judged against the plan
  # context's `invoke_types` snapshot rather than the always-static
  # `Statifier.Send.Target.supported_invoke_type?/1` (ADR-0051 decision 3).
  # A registered type dispatches to its handler module - looked up in
  # `context.invoke_handlers`, defaulting to the built-in `scxml` handler
  # (ADR-0051 decision 4) - and splices `start/2`'s own returned
  # instructions into the plan. `start/2`'s `{:error, _}` is planned as the
  # same `error.execution` shape an unregistered type raises: it is a pure
  # planning failure (no communication was ever attempted, since `start/2`
  # performs none), the same class 3.12.2 assigns an unregistered type to -
  # unlike a *registered* handler's `perform/2` later failing to reach its
  # service, which is `error.communication` (ADR-0051's classification
  # table).
  @spec plan_invoke(invoke :: Invoke.t(), effect :: Effect.t(), context :: context()) :: [
          instruction()
        ]
  defp plan_invoke(invoke, _effect, %{invoke_types: invoke_types} = context) do
    if InvokeTypes.registered?(invoke_types, invoke.type) do
      case handler_module_for_type(invoke.type, context).start(invoke, context) do
        {:ok, instructions} -> instructions
        {:error, _reason} -> [invoke_execution_error(invoke)]
      end
    else
      [invoke_execution_error(invoke)]
    end
  end

  # `plan_invoke/3`'s own type -> handler lookup, factored out so
  # `plan_one/2`'s `:cancel_invoke`/`:autoforward` arms (`handler_for/2`
  # below) can share it rather than re-deriving the default.
  @spec handler_module_for_type(type :: String.t() | nil, context :: context()) :: module()
  defp handler_module_for_type(type, context) do
    context |> Map.get(:invoke_handlers, %{}) |> Map.get(type, ScxmlHandler)
  end

  # `:cancel_invoke`/`:autoforward`'s own handler lookup (ADR-0051 decision
  # 6): `invoke_id`'s type comes from the *live* `invocation_types`
  # snapshot (`Statifier.Session.Invocations.types/1`), not from the effect
  # itself - `Effect.CancelInvoke`/`Effect.Autoforward` carry no `type`
  # field, only `invoke_id`. A miss (the invocation is no longer live at
  # all - already popped by a prior cancel or a handler's own
  # `done_invocation/3`) falls through to `handler_module_for_type/2`'s own
  # `nil` default, `ScxmlHandler` - the same instruction this module
  # emitted unconditionally before this dispatch existed, so a miss changes
  # nothing observable.
  @spec handler_for(invoke_id :: String.t(), context :: context()) :: module()
  defp handler_for(invoke_id, context) do
    type = context |> Map.get(:invocation_types, %{}) |> Map.get(invoke_id)
    handler_module_for_type(type, context)
  end

  @spec invoke_execution_error(invoke :: Invoke.t()) :: instruction()
  defp invoke_execution_error(invoke) do
    {:raise, :platform, "error.execution", {:invoke, invoke.state_index, invoke.invoke_index}, []}
  end

  # 6.2.5's unsupported-`type` error and 6.2.4's unsupported-or-invalid
  # `target` error are the same shape: `error.execution` on the sending
  # session's own internal queue, carrying the failing `<send>`'s `sendid`
  # unconditionally (5.10.1's "the Processor MUST set this field to the send
  # id of the triggering `<send>` element" carries no "if the author
  # specified id", unlike C.1's rule for a *delivered* event's `sendid` -
  # decision 3). No delivery, no timer, for either. As with `plan_send/3`
  # and `plan_send_delayed/3` above, this is the `Session.interpret/2`
  # boundary check ADR-0047 decision 4 keeps: a core-produced `<send>`
  # effect never reaches here with an invalid target or unsupported type,
  # because `Statifier.Machine.Content.Send` already rejected it before
  # building the effect.
  @spec execution_error(send :: Send.t() | SendDelayed.t()) :: instruction()
  defp execution_error(send) do
    {:raise, :platform, "error.execution", {:content, send.c_index, send.owner},
     sendid: send.send_id}
  end

  # C.1's four mappings for a `<send>` with no target, delivered to the
  # sending session's own external queue - and, per decision 10/step 5 above,
  # for every other reachable route too, since `origin`/`origintype`/`sendid`
  # are the *sending* session's own address regardless of where the event
  # ends up: `origin` is this session's own `_ioprocessors` location,
  # `origintype` is the processor's type **URI** rather than the short alias
  # `"scxml"` - see below - and `sendid` is blank unless the author actually
  # named this `<send>` (`id`/`idlocation`), per `id_from_author?`.
  #
  # `origintype` deliberately contradicts C.1's prose, which says the field
  # "MUST have the value \"scxml\"". The W3C's own conformance suite requires
  # the URI instead: test198 sends with *no* `type` attribute at all - the
  # default case - and asserts `_event.origintype ==
  # 'http://www.w3.org/TR/scxml/#SCXMLEventProcessor'`, which only the URI
  # satisfies; test352 asserts the same for an explicitly-typed send; test253
  # accepts either spelling. No test in the corpus requires `"scxml"`. Plan
  # decision 11 picks the URI on that evidence.
  #
  # Known residual, untested either way: this hardcodes the URI regardless of
  # what the author wrote, so `<send type="scxml">` still reports the URI,
  # where 5.10.1's "equivalent to the 'type' field on the `<send>` element"
  # would echo `"scxml"` back. test253 accepts both, and nothing else covers
  # it. Echoing the written value would satisfy every test above too, so this
  # is a free choice until a test constrains it.
  @spec delivered_event(send :: Send.t() | SendDelayed.t(), session_id :: String.t()) ::
          Event.t()
  defp delivered_event(send, session_id) do
    Event.external(send.event,
      data: send.data,
      origin: SystemVariables.scxml_location(session_id),
      origintype: SystemVariables.scxml_event_processor(),
      sendid: if(send.id_from_author?, do: send.send_id),
      caller_context: caller_context_of(send)
    )
  end

  # `<send target="#_internal">`'s own delivered event (5.10.1: "For
  # internal and platform events, the Processor MUST leave [origin and
  # origintype] blank" - `Event.internal/3` never reads them). `sendid` is
  # the same `id_from_author?`-gated rule `delivered_event/2` uses (C.1
  # still requires it on an internally-delivered send). This is only a
  # *carrier* for `Statifier.Session` to read `name`/`data`/`sendid` back off
  # - the actual delivery re-raises through
  # `Statifier.Interpreter.deliver_internal/5`, which builds its own
  # `Cause` from the machine's *current* counters at delivery time (ADR-0039,
  # decision 2), so this event's own `cause` is never read and its
  # macrostep/microstep/round are placeholders - the send's own provenance,
  # not the delivered event's real one.
  @spec internal_event(send :: Send.t() | SendDelayed.t()) :: Event.t()
  defp internal_event(send) do
    cause =
      Cause.new(
        {:content, send.c_index, send.owner},
        send.macrostep,
        send.microstep,
        send.round
      )

    event =
      Event.internal(send.event, cause,
        data: send.data,
        sendid: if(send.id_from_author?, do: send.send_id)
      )

    # ADR-0063 decision 3: the scheduler's opaque caller context travels
    # onto the event this carrier will deliver. Written directly rather
    # than through `Event.internal/3`'s opts, which deliberately never
    # read the slot (decision 2) - this is the one copy site, not a
    # constructor surface.
    %{event | caller_context: caller_context_of(send)}
  end

  # ADR-0063 decision 3's firing-time copy source. Only `%SendDelayed{}`
  # (and `%Cancel{}`, which never reaches these builders) carries the
  # slot; an immediate `%Send{}` is delivered inside the macrostep whose
  # telemetry already carries the context, so it has no field to copy
  # (decision 2) and contributes `nil`. Dispatch is on the struct, never
  # on the value - the library still never reads what the slot holds.
  @spec caller_context_of(send :: Send.t() | SendDelayed.t()) :: term()
  defp caller_context_of(%SendDelayed{caller_context: caller_context}), do: caller_context
  defp caller_context_of(%Send{}), do: nil
end
