defmodule Statifier.Validator.Checks.InitialElement do
  @moduledoc """
  Check 4 (spec 3.3, 3.6): a state's own `<initial>` element.

  Two independent facts about every `<initial>` element in the document:
  `{:initial_attribute_and_element, id}` when the same state also carries
  an `initial` attribute (at most one form is legal), and
  `Statifier.Validator.Checks.DefaultTransition`'s shared sub-check with
  `owner: {:initial, id}` - the element's content model is exactly one
  transition, with a target, no `event`, no `cond`.

  This check does not itself resolve or check the descendancy of the
  `<initial>` transition's target - `Statifier.Validator.Checks.Targets`
  owns existence and
  `Statifier.Validator.Checks.InitialTargets` owns descendancy (check 3).
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Checks.DefaultTransition
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(&(&1.initial_element != nil))
    |> Enum.flat_map(&check_state/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp check_state(%State{initial_element: initial_element} = state) do
    both_forms_errors(state) ++
      DefaultTransition.check(
        {:initial, state.id},
        initial_element.transitions,
        initial_element.location
      )
  end

  defp both_forms_errors(%State{initial: []}), do: []

  defp both_forms_errors(%State{initial: initial, initial_element: initial_element} = state)
       when initial != [] do
    [Error.initial_attribute_and_element(state.id, initial_element.location)]
  end
end
