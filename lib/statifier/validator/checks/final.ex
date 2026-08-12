defmodule Statifier.Validator.Checks.Final do
  @moduledoc """
  Check 6 (spec 3.7): a `:final` state's content model is `onentry`,
  `onexit`, and `donedata` - nothing else. Two reasons, each reported once
  per offending child and at the **child's own** `location` rather than the
  `<final>`'s, so the caret lands on the element that should not be there:

  - `{:final_has_states, id}` for a state child, `id` being the child's.
  - `{:final_has_transitions, id}` for a `<transition>` child, `id` being
    the `<final>`'s - a `<final>` is where a region stops, so it has no
    outgoing transition to take. This case was deferred at first, then
    folded into this module rather than growing a ninth check for one
    more child type.

  An `initial` attribute or `<initial>` element on a `:final` is *not*
  reported here: check 3 already refuses it as `:initial_on_atomic_state`
  (`Checks.InitialTargets`'s `atomic_for_initial?/1` counts `:final`), and
  reporting it twice would be two errors for one mistake.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns a `:final_has_states` error for every state child of a `:final`
  state and a `:final_has_transitions` error for every `<transition>` child
  of one - a `<final>`'s only legal content is `onentry`, `onexit`, and
  `donedata`. An `initial` attribute or `<initial>` element on a `:final` is
  not reported here; check 3 already owns that mistake. Returns `[]` when no
  `:final` state carries an illegal child.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(&(&1.kind == :final))
    |> Enum.flat_map(&check_final/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp check_final(%State{states: children, transitions: transitions} = state) do
    Enum.map(children, fn child -> Error.final_has_states(child.id, child.location) end) ++
      Enum.map(transitions, fn transition ->
        Error.final_has_transitions(state.id, transition.location)
      end)
  end
end
