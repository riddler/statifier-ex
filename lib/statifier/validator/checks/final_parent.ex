defmodule Statifier.Validator.Checks.FinalParent do
  @moduledoc """
  Check 12 (spec 3.7, Appendix D `enterStates`): a `<final>` state's parent
  carries no `id`. Entering a non-top-level `<final>` raises
  `done.state.{parent.id}` (`lib/statifier/interpreter/exit_entry.ex`'s
  `raise_parent_completion/3`), so a parent with no written `id` has a
  completion event the spec names after a name it does not have.

  Deliberately **not** filtered to `kind: :state`:
  `raise_completion_events/2` routes on the entered state being `:final` and
  its `parent != 0`, never on the parent's kind, so a `<final>` written
  directly under a `<parallel>` reaches the same raise site and the same
  missing name. That is the opposite of `Checks.DefaultEntry`'s narrowing to
  `:state` (`checks/default_entry.ex`'s moduledoc), and deliberately so.

  Fires on `id: nil` only, not `id: ""`: `Checks.Ids` already reports
  `{:empty_id}` for every state written `id=""` regardless of what it
  contains, so an empty-id parent of a `<final>` is refused either way and
  reporting it again here would be two errors for one mistake.

  Reports **once per offending parent**, not once per `<final>` child: a
  parent with two `<final>` children has one mistake (one missing `id`). The
  first `<final>` child in document order supplies the reported `final_id`.

  Only ever looks at a `State.t()`'s own `states` list, never
  `Document.states` - a top-level `<final>` (parent `:scxml`) raises no
  `done.state.*` event at all (`raise_completion_events/2`'s `parent == 0`
  arm), so it is outside this rule by construction.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Validator.{Context, Error}

  @doc """
  Returns a `:final_parent_missing_id` error for every state with no written
  `id` that has at least one direct `:final` child, reported once per such
  parent at the parent's own `location`. Returns `[]` when every parent of a
  `<final>` carries an `id`.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.filter(&offending?/1)
    |> Enum.map(&Error.final_parent_missing_id(first_final(&1).id, &1.location))
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp offending?(%State{id: nil, states: children}),
    do: Enum.any?(children, &(&1.kind == :final))

  defp offending?(%State{}), do: false

  defp first_final(%State{states: children}), do: Enum.find(children, &(&1.kind == :final))
end
