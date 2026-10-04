defmodule Statifier.Validator.Checks.History do
  @moduledoc """
  Check 5 (spec 3.10): a `:history` state's placement, default transition,
  and `type`. Four independent facts, per `:history` state in the document:

  - `{:history_bad_parent, id, parent_kind}` when the parent is not a
    compound `<state>` or a `<parallel>` (`Context.compound?/1`, Decision
    6) - the document root, a `:final`, and another `:history` are all
    illegal parents.
  - `Statifier.Validator.Checks.DefaultTransition`'s shared sub-check with
    `owner: {:history, id}` - required, exactly one, a non-null target, no
    `event`, no `cond` (spec 3.10 requires the default transition
    unconditionally, stricter than a looser "when present" reading).
  - `{:initial_not_descendant, target, parent_id}` when a resolved default
    target is not a descendant of the history's own **parent** (spec 3.10)
    - not of the history state itself, which has no descendants of its
      own to test against. Reuses check 3's constructor: this is the same
      shape of mistake, just against a different parent. Skipped when the
      target does not resolve at all (`Statifier.Validator.Checks.Targets`
      already reported that) or when the parent is not compound - a
      non-compound parent has already been reported by
      `:history_bad_parent`, and testing descendancy against it (an id that
      may not even exist, for the document root) would be a second,
      meaningless error for the same mistake. A parent with an `id` is
      tested by id (`Context.descendant?/3`); a parent with no `id` is
      tested by the tree's structure, and the reported `parent_id` is then
      `nil`.
  - `{:history_bad_type, raw}` when `type` was written and, sliced back out
    of `context.source`, is neither `"shallow"` nor `"deep"`.
    Lowering silently maps any out-of-range value to the `:shallow`
    default (Residual Note 2), so the atom on `%State{}` alone cannot tell
    `type="shallow"` from `type="sideways"` - only the raw source text can.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Parser.Location
  alias Statifier.Validator.Checks.DefaultTransition
  alias Statifier.Validator.{Context, Error}

  @doc """
  Returns, per `:history` state in the document, any combination of a
  `:history_bad_parent` error (the parent is not a compound `<state>` or
  `<parallel>`), the shared default-transition errors from
  `Statifier.Validator.Checks.DefaultTransition`, an `:initial_not_descendant`
  error (the default transition's target is not a descendant of the
  history's own parent), and a `:history_bad_type` error (a written `type`
  that is neither `"shallow"` nor `"deep"`). Returns `[]` when every
  `:history` state's placement, default transition, and type are all legal.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{} = context) do
    states
    |> flatten()
    |> Enum.filter(&(&1.kind == :history))
    |> Enum.flat_map(&check_history(&1, context))
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp check_history(%State{} = state, context) do
    parent = Map.fetch!(context.parents, state)

    parent_errors(state, parent) ++
      DefaultTransition.check({:history, state.id}, state.transitions, state.location) ++
      descendancy_errors(state, parent, context) ++
      type_errors(state, context)
  end

  defp parent_errors(state, parent) do
    if compound_parent?(parent) do
      []
    else
      [Error.history_bad_parent(state.id, parent_kind(parent), state.location)]
    end
  end

  defp compound_parent?(%Document{}), do: false
  defp compound_parent?(%State{} = parent), do: Context.compound?(parent)

  defp parent_kind(%Document{}), do: :scxml
  defp parent_kind(%State{kind: kind}), do: kind

  defp descendancy_errors(state, parent, context) do
    if compound_parent?(parent) do
      target_descendancy_errors(state, parent, context)
    else
      []
    end
  end

  defp target_descendancy_errors(
         %State{transitions: transitions},
         %State{id: parent_id} = parent,
         context
       ) do
    Enum.flat_map(transitions, fn transition ->
      location = Map.get(transition.attribute_locations, :target, transition.location)

      transition.target
      |> Enum.filter(&resolved_outside?(&1, parent, context))
      |> Enum.map(&Error.initial_not_descendant(&1, parent_id, location))
    end)
  end

  # An unresolved target is check 2's to report, never this check's. A
  # parent with an id keeps the id test, `Context.descendant?/3`; only a
  # parent with no id is placed by the tree's structure.
  defp resolved_outside?(target, %State{id: nil} = parent, context) do
    case Map.fetch(context.states, target) do
      {:ok, state} -> not Context.inside?(context, state, parent)
      :error -> false
    end
  end

  defp resolved_outside?(target, %State{id: parent_id}, context) do
    Map.has_key?(context.states, target) and not Context.descendant?(context, parent_id, target)
  end

  defp type_errors(%State{attribute_locations: attribute_locations}, context) do
    case Map.fetch(attribute_locations, :type) do
      :error ->
        []

      {:ok, %Location{} = location} ->
        raw = Location.slice(location, context.source)
        if raw in ["shallow", "deep"], do: [], else: [Error.history_bad_type(raw, location)]
    end
  end
end
