defmodule Statifier.Validator.Checks.Ids do
  @moduledoc """
  Check 1 (spec 3.14): a state's `id` is unique across the document. `nil`
  ids are excluded from the uniqueness set (`lib/statifier/document/state.ex`
  - a `nil` id means "the author omitted an optional attribute", not "no
  id"), and document scope, not session scope, is what this layer can see.

  The **first** occurrence of a repeated id in document order is canonical
  and reports nothing; every later occurrence gets its own
  `{:duplicate_id, id}` error.

  A state written as `id=""` is a third case, resolved here rather than
  left open: spec 3.14 types `id` as an XML Schema ID, whose
  lexical space excludes the empty string, so an empty id is
  `{:empty_id}` - and, like a `nil` id, it stays out of the uniqueness set
  entirely. Two states both written `id=""` are two empty ids, not a
  duplicate pair; grouping them would add a third error for a collision
  that is not one.
  """

  alias Statifier.Document
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states = flatten(states)

    empty_id_errors(states) ++ duplicate_id_errors(states)
  end

  defp empty_id_errors(states) do
    states
    |> Enum.filter(fn state -> state.id == "" end)
    |> Enum.map(fn state -> Error.empty_id(id_location(state)) end)
  end

  defp duplicate_id_errors(states) do
    states
    |> Enum.filter(fn state -> state.id not in [nil, ""] end)
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
    Error.duplicate_id(id, id_location(state))
  end

  defp id_location(state) do
    Map.get(state.attribute_locations, :id, state.location)
  end
end
