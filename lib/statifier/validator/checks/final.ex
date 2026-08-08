defmodule Statifier.Validator.Checks.Final do
  @moduledoc """
  Check 6 (spec 3.7): a `:final` state's content model excludes state
  children entirely - only `onentry`, `onexit`, and `donedata` are legal.
  Reports `{:final_has_states, id}` once per state child of a `:final`, at
  the **child's own** `location` rather than the `<final>`'s, so the caret
  lands on the element that should not be there.

  Scope stops exactly at the bead's wording: transitions and `initial` on a
  `:final` are a separate representable-but-invalid shape (st-dje, Decision
  7) this check does not report.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

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

  defp check_final(%State{states: children}) do
    Enum.map(children, fn child -> Error.final_has_states(child.id, child.location) end)
  end
end
