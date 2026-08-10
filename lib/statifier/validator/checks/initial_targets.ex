defmodule Statifier.Validator.Checks.InitialTargets do
  @moduledoc """
  Check 3 (spec 3.3, 3.6): every `initial` reference - a state's `initial`
  attribute, a state's `<initial>` element, and the document's own root
  `initial` attribute - resolves and lands on a legal target. Four reasons,
  in this precedence:

  1. `{:initial_on_atomic_state, id}`: a state carrying
     `initial` or `initial_element` that has nothing to default into - an
     empty `states` list, or a `:parallel`, `:final`, or `:history` kind.
     Fires first and **suppresses every other reason for that state**: an
     atomic state's initial cannot be resolved, checked for descendancy, or
     anything else, so reporting more than this one error would be two
     errors for one mistake.
  2. `{:unresolved_initial, id}`: an id in `State.initial` or
     `Document.initial` absent from `Context.states`. An `<initial>`
     element's own transition targets are **not** re-checked here for
     existence - check 2 already owns that; this check only
     asks `Context.states` the same question check 2 already answered, so
     it can skip the descendancy test below rather than re-reporting.
  3. `{:initial_not_descendant, id, parent_id}`: a resolved target - from
     `State.initial` or from an `<initial>` element's transitions - that is
     not among the containing state's named descendants
     (`Context.descendant?/3`, ancestry all the way up, not direct-child
     membership - spec 3.3/3.6 both say "descendants", which is where v1 is
     wrong).
  4. `{:initial_not_top_level, id}`: a resolved `Document.initial` id that
     is not itself a member of `document.states` - the root has no id of
     its own to run `Context.descendant?/3` against, so "is a top-level
     state" is the substitute spec 3.3's descendancy rule reduces to here.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{} = document, %Context{} = context) do
    state_errors =
      document.states
      |> flatten()
      |> Enum.filter(&(&1.id != nil))
      |> Enum.flat_map(&check_state(&1, context))

    state_errors ++ check_document_initial(document, context)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp check_state(%State{} = state, context) do
    cond do
      not carries_initial?(state) ->
        []

      atomic_for_initial?(state) ->
        [Error.initial_on_atomic_state(state.id, atomic_location(state))]

      true ->
        check_initial_attribute(state, context) ++ check_initial_element(state, context)
    end
  end

  defp carries_initial?(%State{initial: initial, initial_element: initial_element}) do
    initial != [] or initial_element != nil
  end

  defp atomic_for_initial?(%State{states: states, kind: kind}) do
    states == [] or kind in [:parallel, :final, :history]
  end

  defp atomic_location(%State{initial: initial} = state) when initial != [] do
    Map.get(state.attribute_locations, :initial, state.location)
  end

  defp atomic_location(%State{initial_element: initial_element}), do: initial_element.location

  defp check_initial_attribute(%State{initial: []}, _context), do: []

  defp check_initial_attribute(%State{initial: initial} = state, context) do
    location = Map.get(state.attribute_locations, :initial, state.location)

    Enum.flat_map(initial, fn id ->
      cond do
        not Map.has_key?(context.states, id) ->
          [Error.unresolved_initial(id, location)]

        not Context.descendant?(context, state.id, id) ->
          [Error.initial_not_descendant(id, state.id, location)]

        true ->
          []
      end
    end)
  end

  defp check_initial_element(%State{initial_element: nil}, _context), do: []

  defp check_initial_element(%State{initial_element: initial_element} = state, context) do
    Enum.flat_map(initial_element.transitions, fn transition ->
      location = Map.get(transition.attribute_locations, :target, transition.location)

      transition.target
      |> Enum.filter(&Map.has_key?(context.states, &1))
      |> Enum.reject(&Context.descendant?(context, state.id, &1))
      |> Enum.map(&Error.initial_not_descendant(&1, state.id, location))
    end)
  end

  defp check_document_initial(%Document{initial: []}, _context), do: []

  defp check_document_initial(%Document{initial: initial} = document, context) do
    location = Map.get(document.attribute_locations, :initial, document.location)
    top_level_ids = document.states |> Enum.map(& &1.id) |> MapSet.new()

    Enum.flat_map(initial, fn id ->
      cond do
        not Map.has_key?(context.states, id) ->
          [Error.unresolved_initial(id, location)]

        id not in top_level_ids ->
          [Error.initial_not_top_level(id, location)]

        true ->
          []
      end
    end)
  end
end
