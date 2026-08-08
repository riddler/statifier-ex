defmodule Statifier.Validator.Checks.Ids do
  @moduledoc """
  Check 1 (spec 3.14): a state's `id` is unique across the document. `nil`
  ids are excluded from the uniqueness set (`lib/statifier/document/state.ex`
  - a `nil` id means "the author omitted an optional attribute", not "no
  id"), and document scope, not session scope, is what this layer can see
  (`docs/plans/260808-st-l5k.5-document-validator.md` Decision 8).

  The **first** occurrence of a repeated id in document order is canonical
  and reports nothing; every later occurrence gets its own
  `{:duplicate_id, id}` error.
  """

  alias Statifier.Document
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(fn state -> state.id != nil end)
    |> Enum.group_by(fn state -> state.id end)
    |> Enum.flat_map(fn {id, occurrences} -> duplicate_errors(id, occurrences) end)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp duplicate_errors(_id, [_first]), do: []

  defp duplicate_errors(id, [_first | rest]) do
    Enum.map(rest, fn state -> duplicate_error(id, state) end)
  end

  defp duplicate_error(id, state) do
    location = Map.get(state.attribute_locations, :id, state.location)
    Error.duplicate_id(id, location)
  end
end
