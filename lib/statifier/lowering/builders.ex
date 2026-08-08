defmodule Statifier.Lowering.Builders do
  @moduledoc """
  One `build_*` function per supported SCXML element, reached through
  `Statifier.Lowering`'s dispatch map - the structural fix for v1's
  903-line, 73-clause `state_stack.ex` (`docs/architecture.md`,
  "adding an element touches one builder").

  Every builder lowers its own children first, through
  `Statifier.Lowering.walk_children/2`, before building its own struct, so
  errors accumulate in document order regardless of nesting depth. No
  builder here takes a parent element name as an argument (Decision 3):
  placement of a tagged child result into a parent's slot is each
  container's own `place/3` (from Phase 2 on), never a fact the child
  itself needs to know.
  """

  alias Statifier.Document
  alias Statifier.Document.Initial
  alias Statifier.Document.State
  alias Statifier.Document.Transition
  alias Statifier.Lowering
  alias Statifier.Lowering.Attributes
  alias Statifier.Lowering.Error
  alias Statifier.Parser.DOM.Element

  @binding_values %{"early" => :early, "late" => :late}
  @history_type_values %{"shallow" => :shallow, "deep" => :deep}
  @transition_type_values %{"internal" => :internal, "external" => :external}

  @doc """
  Builds the `%Statifier.Document{}` root from `<scxml>`.

  Reads `initial` (whitespace-split), `name`, `datamodel`, `binding` (atom,
  default `:early`), `version`, and `xmlns`. `<state>`, `<parallel>`, and
  `<final>` children are placed into `Document.states`, in document order;
  any other child misses `Document`'s one slot and is reported via `place/3`
  as `{:misplaced_element, name, "scxml"}`.
  """
  @spec build_scxml(element :: Element.t(), ctx :: map()) :: {Document.t(), [Error.t()]}
  def build_scxml(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:initial, element, "initial")
      |> Attributes.put_location(:name, element, "name")
      |> Attributes.put_location(:datamodel, element, "datamodel")
      |> Attributes.put_location(:binding, element, "binding")
      |> Attributes.put_location(:version, element, "version")
      |> Attributes.put_location(:xmlns, element, "xmlns")

    document = %Document{
      location: element.location,
      initial: Attributes.list(element, "initial"),
      name: Attributes.value(element, "name"),
      datamodel: Attributes.value(element, "datamodel"),
      binding: Attributes.atom(element, "binding", @binding_values, :early),
      version: Attributes.value(element, "version"),
      xmlns: Attributes.value(element, "xmlns"),
      attribute_locations: attribute_locations
    }

    {document, place_errors} = place_children(results, document, element.name)
    document = reverse_lists(document)

    {document, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :state` from `<state>`.
  """
  @spec build_state(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_state(%Element{} = element, ctx), do: state_like(element, ctx, :state)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :parallel` from
  `<parallel>`.
  """
  @spec build_parallel(element :: Element.t(), ctx :: map()) ::
          {{:state, State.t()}, [Error.t()]}
  def build_parallel(%Element{} = element, ctx), do: state_like(element, ctx, :parallel)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :final` from `<final>`.
  """
  @spec build_final(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_final(%Element{} = element, ctx), do: state_like(element, ctx, :final)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :history` from
  `<history>`.

  Additionally reads `type`, mapped to `:shallow | :deep` with `:shallow` as
  the default (spec 3.10) - an out-of-range value (`type="sideways"`) lowers
  to `:shallow` and still keeps its `attribute_locations` entry, rather than
  erroring (Residual Note 2).
  """
  @spec build_history(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_history(%Element{} = element, ctx) do
    {{:state, state}, errors} = state_like(element, ctx, :history)

    state = %{
      state
      | history_type: Attributes.atom(element, "type", @history_type_values, :shallow),
        attribute_locations:
          Attributes.put_location(state.attribute_locations, :type, element, "type")
    }

    {{:state, state}, errors}
  end

  @doc """
  Builds a `%Statifier.Document.Initial{}` from `<initial>`.

  `transitions` holds however many `<transition>` children are present,
  including zero and two - lowering builds what is written; the transition
  count is st-l5k.5's check to make (`Statifier.Document.Initial`'s
  moduledoc).
  """
  @spec build_initial(element :: Element.t(), ctx :: map()) ::
          {{:initial, Initial.t()}, [Error.t()]}
  def build_initial(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    initial = %Initial{location: element.location}
    {initial, place_errors} = place_children(results, initial, element.name)
    initial = reverse_lists(initial)

    {{:initial, initial}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Transition{}` from `<transition>`.

  Reads `event` and `target` (both whitespace-split), `cond` (raw source
  string), and `type` (atom, default `:external`). An out-of-range `type`
  value lowers to `:external` and still keeps its `attribute_locations`
  entry (Residual Note 2), the same rule `<history>`'s `type` follows.
  """
  @spec build_transition(element :: Element.t(), ctx :: map()) ::
          {{:transition, Transition.t()}, [Error.t()]}
  def build_transition(%Element{} = element, ctx) do
    {_results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:event, element, "event")
      |> Attributes.put_location(:target, element, "target")
      |> Attributes.put_location(:cond, element, "cond")
      |> Attributes.put_location(:type, element, "type")

    transition = %Transition{
      location: element.location,
      event: Attributes.list(element, "event"),
      target: Attributes.list(element, "target"),
      cond: Attributes.value(element, "cond"),
      type: Attributes.atom(element, "type", @transition_type_values, :external),
      attribute_locations: attribute_locations
    }

    {{:transition, transition}, errors}
  end

  # Shared by `build_state/2`, `build_parallel/2`, `build_final/2`, and
  # `build_history/2` (`state_like/3` takes a `kind` atom, its own
  # contribution - never a parent element name, per Decision 3). Reads the
  # attributes meaningful across the state family (`id`, `initial`), places
  # its children into `states`, `transitions`, and `initial_element` via
  # `place/3`, and tags the result `{:state, state}` - the slot every one of
  # the four kinds is placed into by its own parent, regardless of which of
  # the four it is.
  @spec state_like(element :: Element.t(), ctx :: map(), kind :: Document.state_kind()) ::
          {{:state, State.t()}, [Error.t()]}
  defp state_like(%Element{} = element, ctx, kind) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:id, element, "id")
      |> Attributes.put_location(:initial, element, "initial")

    state = %State{
      kind: kind,
      location: element.location,
      id: Attributes.value(element, "id"),
      initial: Attributes.list(element, "initial"),
      attribute_locations: attribute_locations
    }

    {state, place_errors} = place_children(results, state, element.name)
    state = reverse_lists(state)

    {{:state, state}, errors ++ place_errors}
  end

  # Folds `results` (a container's own tagged, walked children) into
  # `container` via `place/3`, threading errors alongside. List slots are
  # prepended here and reversed once by `reverse_lists/1`, never appended per
  # child.
  @spec place_children(results :: [term()], container :: struct(), parent_name :: binary()) ::
          {struct(), [Error.t()]}
  defp place_children(results, container, parent_name) do
    Enum.reduce(results, {container, []}, fn result, {container, errors} ->
      case place(result, container, parent_name) do
        {container, nil} -> {container, errors}
        {container, error} -> {container, [error | errors]}
      end
    end)
  end

  # One clause per slot the container owns; the catch-all reports
  # `{:misplaced_element, name, parent_name}` for anything else, deriving
  # `name` from the child's own tag rather than a hardcoded literal - every
  # tag besides `:state` names exactly one element, and `:state` never
  # reaches the catch-all since both containers that accept state-family
  # children own the `states` slot.
  @spec place(child :: term(), container :: struct(), parent_name :: binary()) ::
          {struct(), Error.t() | nil}
  defp place({:state, state}, %State{} = parent, _parent_name) do
    {%{parent | states: [state | parent.states]}, nil}
  end

  defp place({:transition, transition}, %State{} = parent, _parent_name) do
    {%{parent | transitions: [transition | parent.transitions]}, nil}
  end

  defp place({:initial, initial}, %State{} = parent, _parent_name) do
    {%{parent | initial_element: initial}, nil}
  end

  defp place({:transition, transition}, %Initial{} = parent, _parent_name) do
    {%{parent | transitions: [transition | parent.transitions]}, nil}
  end

  defp place({:state, state}, %Document{} = parent, _parent_name) do
    {%{parent | states: [state | parent.states]}, nil}
  end

  defp place({tag, value}, parent, parent_name) do
    {parent, Error.misplaced(Atom.to_string(tag), parent_name, Map.fetch!(value, :location))}
  end

  @spec reverse_lists(container :: struct()) :: struct()
  defp reverse_lists(%State{} = state) do
    %{state | states: Enum.reverse(state.states), transitions: Enum.reverse(state.transitions)}
  end

  defp reverse_lists(%Initial{} = initial) do
    %{initial | transitions: Enum.reverse(initial.transitions)}
  end

  defp reverse_lists(%Document{} = document) do
    %{document | states: Enum.reverse(document.states)}
  end
end
