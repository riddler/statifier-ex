defmodule Statifier.Validator.Checks.DefaultTransition do
  @moduledoc """
  The sub-check checks 4 and 5 share (Decision 8): an `<initial>` element's
  and a `:history` state's whole content model is one constrained
  `<transition>` - required, exactly one, a non-null `target`, no `event`,
  no `cond`. Spec 3.6 states this for `<initial>`; spec 3.10 states it for
  `<history>`'s default transition, more strictly than the bead's own
  wording ("when present") - Decision 8 records the divergence.

  `Statifier.Document.Initial.transitions` and a `:history` state's own
  `transitions` share the same `[Transition.t()]` shape
  (`lib/statifier/document/initial.ex`), so one function serves both -
  `check/3` never needs to know which element it is looking at beyond the
  `owner` tag it is handed.

  This module is not itself one of `Statifier.Validator`'s `@checks` - it
  has no standalone entry, only a `check/3` consumed by
  `Statifier.Validator.Checks.InitialElement` and
  `Statifier.Validator.Checks.History`.

  The `event` oracle is `Map.has_key?(transition.attribute_locations, :event)`,
  because `Statifier.Lowering.Attributes.list/2` returns `[]` for both an
  absent `event` and `event=""` - the list alone cannot tell the two apart.
  This inherits a narrowing already accepted for `Statifier.Lowering.Attributes.put_location/4`:
  a written attribute whose `value_location` is `nil` (the parser handler's
  short-scan tolerance) never gets an `attribute_locations` entry either, so
  a document that trips *both* that tolerance *and* writes `event=""` slips
  past this check unreported. Accepted: it is the only oracle available at
  this layer, and closing it means changing what lowering records, which is
  st-l5k.4's contract, not this bead's. `cond` needs no such oracle - it is
  `nil` when absent and `""` when written empty, so `!= nil` is exact.
  """

  alias Statifier.Document.Transition
  alias Statifier.Parser.Location
  alias Statifier.Validator.Error

  @doc """
  `owner` identifies which element's content model is being checked
  (`{:initial, id}` or `{:history, id}`); `transitions` is that element's
  transition list; `owner_location` is where a wrong *count* is reported -
  the element itself has no transition to point at when the count is zero.
  """
  @spec check(
          owner :: Error.owner(),
          transitions :: [Transition.t()],
          owner_location :: Location.t()
        ) ::
          [Error.t()]
  def check(owner, transitions, %Location{} = owner_location) do
    count_errors(owner, transitions, owner_location) ++
      Enum.flat_map(transitions, &transition_errors(owner, &1))
  end

  defp count_errors(owner, transitions, owner_location) do
    case length(transitions) do
      1 -> []
      count -> [Error.transition_count(owner, count, owner_location)]
    end
  end

  defp transition_errors(owner, %Transition{} = transition) do
    missing_target_errors(owner, transition) ++ forbidden_attribute_errors(owner, transition)
  end

  defp missing_target_errors(owner, %Transition{target: []} = transition) do
    [Error.transition_missing_target(owner, transition.location)]
  end

  defp missing_target_errors(_owner, %Transition{}), do: []

  defp forbidden_attribute_errors(owner, %Transition{} = transition) do
    [:event, :cond]
    |> Enum.filter(&forbidden?(transition, &1))
    |> Enum.map(&forbidden_attribute_error(owner, transition, &1))
  end

  defp forbidden?(%Transition{attribute_locations: attribute_locations}, :event) do
    Map.has_key?(attribute_locations, :event)
  end

  defp forbidden?(%Transition{cond: cond}, :cond), do: cond != nil

  defp forbidden_attribute_error(owner, %Transition{} = transition, attr) do
    location = Map.get(transition.attribute_locations, attr, transition.location)
    Error.transition_forbidden_attribute(owner, attr, location)
  end
end
