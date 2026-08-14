defmodule Statifier.Evaluator.Functions do
  @moduledoc """
  The `Predicator.FunctionProvider` carrying `In/1` (spec 5.10), replacing
  `Statifier.Evaluator`'s former private closure-building helper.

  A provider entry is named by `{module, atom}` rather than by a captured
  `function()` value (`deps/predicator/lib/predicator/functions/provider.ex`),
  so `in_state/2` reads the current configuration from its
  `%Predicator.Context{}` argument's `host` slot instead of closing over it.
  `Statifier.Evaluator.context/1` sets `host` to `{machine, configuration}`
  and refreshes it per site with `Predicator.Context.put_host/2` - see that
  module's moduledoc for why this dissolves the "not a resumable position"
  ground the closure used to force.
  """

  @behaviour Predicator.FunctionProvider

  alias Statifier.Machine

  @functions %{"In" => {1, :in_state}}

  @doc """
  This provider's one entry: `In/1`, dispatched to `in_state/2`.
  """
  @impl Predicator.FunctionProvider
  @spec functions() :: %{String.t() => {non_neg_integer(), atom()}}
  def functions, do: @functions

  # The `In(stateId)` host function (spec 5.10): true when `stateId` names a
  # state currently in the context's host configuration. `Machine.index/2`
  # returns `:error` for an id the document never declared - that is not an
  # evaluation failure, so it becomes `{:ok, false}` rather than an
  # `{:error, _}` here; a document asking `In()` about a state it does not
  # have is answered "not active", the same answer it would get for any
  # other inactive state.
  @doc """
  `In(stateId)`: true when `stateId` names a state in `context.host`'s
  configuration, false for an inactive or undeclared state id.

  `context.host` must be `{machine, configuration}`, the shape
  `Statifier.Evaluator.context/1` sets via `Predicator.Context.put_host/2`.
  """
  @spec in_state(args :: [Predicator.Types.value()], context :: Predicator.Context.t()) ::
          {:ok, boolean()}
  def in_state([state_id], %Predicator.Context{host: {machine, configuration}}) do
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
