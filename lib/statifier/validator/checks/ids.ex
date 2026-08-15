defmodule Statifier.Validator.Checks.Ids do
  @moduledoc """
  Check 1 (spec 3.14): an `ID`-typed attribute's value is unique across the
  document - not only a state's `id`, but a `<data>`'s too. 3.14: "all
  attributes of type \"ID\" MUST have unique values within an SCXML
  document", and `<data>`'s `id` is type `ID` (5.3.1) - so a
  `<data id="s1">` colliding with a `<state id="s1">` is exactly as much a
  violation as two states sharing one id, and both join **one** uniqueness
  set rather than two separate ones. `nil` ids are excluded
  (`lib/statifier/document/state.ex` - a `nil` id means "the author omitted
  an optional attribute", not "no id"; `<data>` has no `nil` id, since `id`
  is required to build a `Data` struct at all), and document scope, not
  session scope, is what this layer can see.

  The **first** occurrence of a repeated id in document order is canonical
  and reports nothing; every later occurrence gets its own
  `{:duplicate_id, id}` error - a `<data>` colliding with an earlier
  `<state>` (or vice versa) is reported at the later element's own span,
  never at the canonical, earlier one.

  A state or `<data>` written as `id=""` is a third case, resolved here
  rather than left open: spec 3.14 types `id` as an XML Schema ID, whose
  lexical space excludes the empty string, so an empty id is
  `{:empty_id}` - and, like a `nil` id, it stays out of the uniqueness set
  entirely. Two elements both written `id=""` are two empty ids, not a
  duplicate pair; grouping them would add a third error for a collision
  that is not one.
  """

  alias Statifier.Document
  alias Statifier.Document.Data
  alias Statifier.Document.Datamodel
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns an `:empty_id` error for every state or `<data>` written `id=""`
  and a `:duplicate_id` error for every occurrence of a repeated non-empty
  id after its first, canonical occurrence in document order. `nil` ids (an
  omitted optional attribute) are excluded entirely. Returns `[]` when every
  id in the document is unique or absent.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states, datamodel_element: root_datamodel}, %Context{}) do
    entries = entries(root_datamodel, states)

    empty_id_errors(entries) ++ duplicate_id_errors(entries)
  end

  defp entries(root_datamodel, states) do
    (datamodel_entries(root_datamodel) ++ state_entries(states))
    |> Enum.sort_by(fn {_id, location} -> location.start_offset end)
  end

  defp state_entries(states) do
    Enum.flat_map(states, fn %State{} = state ->
      [{state.id, id_location(state)}] ++
        datamodel_entries(state.datamodel_element) ++ state_entries(state.states)
    end)
  end

  defp datamodel_entries(nil), do: []

  defp datamodel_entries(%Datamodel{data: data}) do
    Enum.map(data, fn %Data{} = data -> {data.id, id_location(data)} end)
  end

  defp empty_id_errors(entries) do
    entries
    |> Enum.filter(fn {id, _location} -> id == "" end)
    |> Enum.map(fn {_id, location} -> Error.empty_id(location) end)
  end

  defp duplicate_id_errors(entries) do
    entries
    |> Enum.filter(fn {id, _location} -> id not in [nil, ""] end)
    |> Enum.group_by(fn {id, _location} -> id end)
    |> Enum.flat_map(fn {id, occurrences} -> duplicate_errors(id, occurrences) end)
  end

  defp duplicate_errors(_id, [_first]), do: []

  defp duplicate_errors(id, [_first | rest]) do
    Enum.map(rest, fn {_id, location} -> Error.duplicate_id(id, location) end)
  end

  defp id_location(%{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :id, location)
  end
end
