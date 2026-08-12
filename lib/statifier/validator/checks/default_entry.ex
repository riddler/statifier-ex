defmodule Statifier.Validator.Checks.DefaultEntry do
  @moduledoc """
  Check 7 (spec 3.3): a compound `<state>` with no `initial`
  attribute and no `<initial>` element falls back to entering its first
  child in document order (spec 3.3). That fallback is only legal when the
  first child is itself enterable - a `:history` pseudo-state is not, since
  spec 3.10 makes it entered only by a transition that targets it
  explicitly - "enterable" here means "not a history pseudo-state".

  Reports `{:default_entry_not_enterable, id, :history}` once per offending
  state, at the first child's own `location`. Fires only when all five
  conditions hold: `kind: :state`, no `initial` attribute, no
  `initial_element`, a non-empty `states` list, and that list's first
  element has `kind: :history`. A state with no children at all (atomic -
  nothing to default into) and a state whose history child is not first (a
  legal sibling of a real default target) both report nothing.

  `kind: :state` is load-bearing, and deliberately narrower than
  `Statifier.Validator.Context.compound?/1`, which counts `:parallel` too.
  A `<parallel>` enters *every* one of its regions on entry (spec 3.4), so
  it has no positional default entry for a leading `<history>` to be wrong
  about - and SCION's `history3`, `history4`, `history4b`, and `history5`
  all open a `<parallel>` with exactly that child order. Widening this to
  `compound?/1` rejects four valid conformance documents.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns a `:default_entry_not_enterable` error for every compound `<state>`
  that has neither an `initial` attribute nor an `<initial>` element and
  whose first child in document order is a `:history` pseudo-state - since
  document-order fallback would otherwise try to enter a state spec 3.10
  forbids entering that way. Returns `[]` when every implicit default entry
  in the document lands on a real state.
  """
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

  defp candidate?(%State{
         kind: :state,
         initial: [],
         initial_element: nil,
         states: [_first | _rest]
       }),
       do: true

  defp candidate?(%State{}), do: false

  defp check_state(%State{id: id, states: [%State{kind: :history} = first | _rest]}) do
    [Error.default_entry_not_enterable(id, :history, first.location)]
  end

  defp check_state(%State{}), do: []
end
