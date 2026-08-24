defmodule Statifier.Invoke.Handler.Scxml do
  @moduledoc """
  The built-in `type=scxml` (and long-URI, `http://www.w3.org/TR/scxml/`)
  `Statifier.Invoke.Handler` - `Statifier.Session.Effects.plan_invoke`'s
  default entry for the built-in type set, not a name it special-cases
  (ADR-0051 decision 4).

  Every instruction below is exactly what `plan_invoke/3` produced directly
  before this module existed, so `Statifier.Session.perform_instruction`'s
  `{:start_child, ...}` clause, `Statifier.Invoke.Source.resolve/2`, the
  6.4.3 child-datamodel seeding, and both process monitors are unchanged -
  this module only names the seam they already sat behind.

  `cancel/2` and `forward/3` return the same `{:stop_child, _}`/`{:forward,
  _, _}` instructions the planner already emits directly today for
  `:cancel_invoke`/`:autoforward` effects; the planner does not yet route
  through them (that routing is a later phase's work), so as written they
  are correct but not yet reachable from `plan/2`. `perform/2` is not
  implemented: every instruction this handler returns already has its own
  executor clause in `Statifier.Session` (and its own no-op clause in
  `Statifier.Replay`), so there is nothing for an impure `perform/2` to do.
  """

  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Invoke.Handler

  @impl Handler
  @spec start(invoke :: Invoke.t(), ctx :: Handler.ctx()) :: {:ok, [Handler.instruction()]}
  def start(%Invoke{} = invoke, _ctx) do
    {:ok, [{:start_child, invoke, {:invoke, invoke}}]}
  end

  @impl Handler
  @spec cancel(invoke_id :: String.t(), ctx :: Handler.ctx()) :: {:ok, [Handler.instruction()]}
  def cancel(invoke_id, _ctx) when is_binary(invoke_id) do
    {:ok, [{:stop_child, invoke_id}]}
  end

  @impl Handler
  @spec forward(invoke_id :: String.t(), event :: Event.t(), ctx :: Handler.ctx()) ::
          {:ok, [Handler.instruction()]}
  def forward(invoke_id, %Event{} = event, _ctx) when is_binary(invoke_id) do
    {:ok, [{:forward, invoke_id, event}]}
  end
end
