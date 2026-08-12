defmodule Statifier.Validator.Checks.Targets do
  @moduledoc """
  Check 2 (spec 3.5): every `<transition>`'s `target` id resolves to a
  state in the document. Walks `Context.transitions` - every owner
  (`:plain`, `:initial`, `:history`) in one traversal - and reports
  `{:unresolved_target, id}` per unresolved id, at that transition's own
  `target` span (falling back to the transition's own span when
  unwritten).

  This check **owns target existence** for every transition in the
  document ("one rule, one owner"): later checks that also
  walk transition targets (checks 3 and 5) must not re-report an id this
  check already reported unresolved. They do not need anything extra from
  `Context` to honor that - "unresolved" and "absent from `Context.states`"
  are the same fact, so a plain `Map.has_key?(context.states, id)` lookup
  is exactly the skip test those checks need.
  """

  alias Statifier.Document
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns an `:unresolved_target` error for every `<transition>` in the
  document (plain, `<initial>`, and `<history>` default alike) whose `target`
  id does not resolve to a state in `Context.states`. Owns target existence
  for the whole document, so later checks may treat an id this check already
  reported as already handled rather than re-reporting it. Returns `[]` when
  every transition target resolves.
  """
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
