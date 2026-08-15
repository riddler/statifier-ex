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

  The event a `:send` becomes is `type: :external` and `cause: nil`, per
  `Statifier.Event.external/2` and the reasoning in `Statifier.Event.internal/3`'s
  `@doc`: a `<send>` with no `target` lands on the sending session's own
  external queue, not on the internal one. Every other target - `#_internal`
  included - plans as `{:unroutable, effect}`, since target routing beyond
  the absent target is not this bead's work.
  """

  alias Statifier.Effect
  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event

  @typedoc "One instruction for `Statifier.Session` to perform."
  @type instruction ::
          {:notify, Effect.t()}
          | {:enqueue_event, Event.t()}
          | {:schedule, send_id :: String.t() | nil, delay_ms :: non_neg_integer(), Event.t()}
          | {:cancel_timers, send_id :: String.t()}
          | {:unroutable, Effect.t()}
          | {:halt, :done | :budget_exhausted}

  @doc """
  Plans `effects`, the core's own order preserved, into the instructions
  `Statifier.Session` performs. `session_id` is the sending session's own id
  (spec 5.10's `_sessionid`), needed to build a delivered event's `origin`.
  `:log` and `:trace` effects plan to nothing but their own
  `{:notify, effect}`.
  """
  @spec plan(effects :: [Effect.t()], session_id :: String.t()) :: [instruction()]
  def plan(effects, session_id) when is_list(effects) and is_binary(session_id) do
    Enum.flat_map(effects, &plan_one(&1, session_id))
  end

  @spec plan_one(effect :: Effect.t(), session_id :: String.t()) :: [instruction()]
  defp plan_one({:send, %Send{target: nil} = send} = effect, session_id) do
    [{:notify, effect}, {:enqueue_event, delivered_event(send, session_id)}]
  end

  defp plan_one({:send, %Send{}} = effect, _session_id) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:send_delayed, %SendDelayed{target: nil} = send} = effect, session_id) do
    event = delivered_event(send, session_id)
    [{:notify, effect}, {:schedule, send.send_id, send.delay_ms, event}]
  end

  defp plan_one({:send_delayed, %SendDelayed{}} = effect, _session_id) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:cancel, %Cancel{send_id: send_id}} = effect, _session_id) do
    [{:notify, effect}, {:cancel_timers, send_id}]
  end

  defp plan_one({:invoke, _invoke} = effect, _session_id) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:cancel_invoke, %CancelInvoke{}} = effect, _session_id) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:autoforward, %Autoforward{}} = effect, _session_id) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:done, _done} = effect, _session_id) do
    [{:notify, effect}, {:halt, :done}]
  end

  defp plan_one({:budget_exhausted, _budget_exhausted} = effect, _session_id) do
    [{:notify, effect}, {:halt, :budget_exhausted}]
  end

  defp plan_one({:log, _log} = effect, _session_id), do: [{:notify, effect}]
  defp plan_one({:trace, _payload} = effect, _session_id), do: [{:notify, effect}]

  # C.1's four mappings for a `<send>` with no target, delivered to the
  # sending session's own external queue: `origin` is this session's own
  # `_ioprocessors` location, `origintype` is the processor's type **URI**
  # rather than the short alias `"scxml"` - plan decision 11 argues the
  # C.1-prose-versus-test352 conflict and picks the URI - and `sendid` is
  # blank unless the author actually named this `<send>` (`id`/`idlocation`),
  # per `id_from_author?`.
  @spec delivered_event(send :: Send.t() | SendDelayed.t(), session_id :: String.t()) ::
          Event.t()
  defp delivered_event(send, session_id) do
    Event.external(send.event,
      data: send.data,
      origin: SystemVariables.scxml_location(session_id),
      origintype: SystemVariables.scxml_event_processor(),
      sendid: if(send.id_from_author?, do: send.send_id)
    )
  end
end
