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
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
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
  `Statifier.Session` performs. `:log` and `:trace` effects plan to nothing
  but their own `{:notify, effect}`.
  """
  @spec plan(effects :: [Effect.t()]) :: [instruction()]
  def plan(effects) when is_list(effects) do
    Enum.flat_map(effects, &plan_one/1)
  end

  @spec plan_one(effect :: Effect.t()) :: [instruction()]
  defp plan_one({:send, %Send{target: nil} = send} = effect) do
    [{:notify, effect}, {:enqueue_event, Event.external(send.event, data: send.data)}]
  end

  defp plan_one({:send, %Send{}} = effect) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:send_delayed, %SendDelayed{target: nil} = send} = effect) do
    event = Event.external(send.event, data: send.data)
    [{:notify, effect}, {:schedule, send.send_id, send.delay_ms, event}]
  end

  defp plan_one({:send_delayed, %SendDelayed{}} = effect) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:cancel, %Cancel{send_id: send_id}} = effect) do
    [{:notify, effect}, {:cancel_timers, send_id}]
  end

  defp plan_one({:invoke, _invoke} = effect) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:cancel_invoke, %CancelInvoke{}} = effect) do
    [{:notify, effect}, {:unroutable, effect}]
  end

  defp plan_one({:done, _done} = effect) do
    [{:notify, effect}, {:halt, :done}]
  end

  defp plan_one({:budget_exhausted, _budget_exhausted} = effect) do
    [{:notify, effect}, {:halt, :budget_exhausted}]
  end

  defp plan_one({:log, _log} = effect), do: [{:notify, effect}]
  defp plan_one({:trace, _payload} = effect), do: [{:notify, effect}]
end
