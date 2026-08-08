defmodule Statifier.Validator.Checks.DefaultEntry do
  @moduledoc """
  Check 7 (spec 3.3, Decision 6): a state with no `initial` attribute and
  no `<initial>` element falls back to entering its first child in
  document order (spec 3.3). That fallback is only legal when the first
  child is itself enterable - a `:history` pseudo-state is not, since spec
  3.10 makes it entered only by a transition that targets it explicitly
  (Decision 6's "enterable" == "not a history pseudo-state").

  Reports `{:default_entry_not_enterable, id, :history}` once per offending
  state, at the first child's own `location`. Fires only when all four
  conditions hold: no `initial` attribute, no `initial_element`, a
  non-empty `states` list, and that list's first element has
  `kind: :history`. A state with no children at all (atomic - nothing to
  default into) and a state whose history child is not first (a legal
  sibling of a real default target) both report nothing.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(&candidate?/1)
    |> Enum.flat_map(&check_state/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp candidate?(%State{initial: [], initial_element: nil, states: [_first | _rest]}), do: true
  defp candidate?(%State{}), do: false

  defp check_state(%State{id: id, states: [%State{kind: :history} = first | _rest]}) do
    [Error.default_entry_not_enterable(id, :history, first.location)]
  end

  defp check_state(%State{}), do: []
end
