defmodule Statifier.Validator.Checks.Targets do
  @moduledoc """
  Check 2 (spec 3.5): every `<transition>`'s `target` id resolves to a
  state in the document. Walks `Context.transitions` - every owner
  (`:plain`, `:initial`, `:history`) in one traversal - and reports
  `{:unresolved_target, id}` per unresolved id, at that transition's own
  `target` span (falling back to the transition's own span when
  unwritten).

  This check **owns target existence** for every transition in the
  document (Decision 5, "one rule, one owner"): later checks that also
  walk transition targets (checks 3 and 5) must not re-report an id this
  check already reported unresolved. They do not need anything extra from
  `Context` to honor that - "unresolved" and "absent from `Context.states`"
  are the same fact, so a plain `Map.has_key?(context.states, id)` lookup
  is exactly the skip test those checks need.
  """

  alias Statifier.Document
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{}, %Context{transitions: transitions} = context) do
    Enum.flat_map(transitions, fn {transition, _owner} ->
      unresolved_errors(transition, context)
    end)
  end

  defp unresolved_errors(transition, context) do
    location = Map.get(transition.attribute_locations, :target, transition.location)

    transition.target
    |> Enum.reject(&Map.has_key?(context.states, &1))
    |> Enum.map(&Error.unresolved_target(&1, location))
  end
end
