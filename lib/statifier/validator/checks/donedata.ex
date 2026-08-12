defmodule Statifier.Validator.Checks.Donedata do
  @moduledoc """
  Check 8 (spec 3.7, 5.7): `<donedata>` is only legal on a `:final` state.
  Reports `{:donedata_not_on_final, id}` for any non-`:final` state
  carrying a non-nil `donedata`, at the `donedata`'s own `location` -
  `lib/statifier/document/donedata.ex` names this check as the layer that
  reports the shape rather than one that refuses to build it.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns a `:donedata_not_on_final` error for every state that carries a
  non-nil `donedata` but is not itself a `:final` state. Returns `[]` when
  every `<donedata>` element in the document sits on a `<final>`.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(&offending?/1)
    |> Enum.map(&Error.donedata_not_on_final(&1.id, &1.donedata.location))
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp offending?(%State{kind: :final}), do: false
  defp offending?(%State{donedata: nil}), do: false
  defp offending?(%State{}), do: true
end
