defmodule Statifier.Validator.Context do
  @moduledoc """
  The throwaway index the checks share, built once per `Statifier.Validator.validate/2`
  call and discarded afterward. It must never be returned, cached, or handed
  to the compiler: `Statifier.Compiler` builds the real interned index, and
  sharing this one would couple two layers the architecture keeps
  independent. Correctness over speed here, per the bead's own design note.

  `states` maps a named state's id to its struct. `ancestors` maps a named
  state's id to the list of its named ancestors' ids, root-first, itself
  excluded - `descendant?/3` turns that into a list-membership test rather
  than a re-walk. A state with a `nil` id cannot be named by anything, so it
  is absent from both maps.

  `parents` maps **every** state struct (nameless ones included) to its
  immediate parent - another `State.t()`, or the `Document.t()` for a
  top-level state - which is why it is keyed by the struct itself rather
  than by id.

  `transitions` is the flat `[{transition, owner}]` list: every
  `<transition>` in the document, tagged with the slot it
  came from. `owner` is `{:plain, state}` for a state's or parallel's own
  transitions, `{:initial, state}` for the transitions inside that state's
  `<initial>` element, and `{:history, state}` for a `:history` state's own
  transitions (its default-transition candidates). Checks 2, 4, and 5 all
  consume this one traversal instead of each re-walking the tree.
  """

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Document.Transition

  @enforce_keys [:source, :states, :ancestors, :parents, :transitions]
  defstruct [:source, :states, :ancestors, :parents, :transitions]

  @type owner :: {:plain, State.t()} | {:initial, State.t()} | {:history, State.t()}

  @type t :: %__MODULE__{
          source: binary(),
          states: %{optional(String.t()) => State.t()},
          ancestors: %{optional(String.t()) => [String.t()]},
          parents: %{State.t() => State.t() | Document.t()},
          transitions: [{Transition.t(), owner()}]
        }

  @doc """
  Walks `document` once, threading ancestry as it descends and collecting
  the shared transition list. `source` is the binary `document` was parsed
  from; it is stored verbatim for checks that need `Location.slice/2`
  and is not otherwise read here.
  """
  @spec build(document :: Document.t(), source :: binary()) :: t()
  def build(%Document{states: states} = document, source) when is_binary(source) do
    {states_map, ancestors, parents, transitions} = walk(states, document, [])

    %__MODULE__{
      source: source,
      states: states_map,
      ancestors: ancestors,
      parents: parents,
      transitions: transitions
    }
  end

  @doc """
  Whether `ancestor_id` is one of `descendant_id`'s named ancestors.
  """
  @spec descendant?(context :: t(), ancestor_id :: String.t(), descendant_id :: String.t()) ::
          boolean()
  def descendant?(%__MODULE__{ancestors: ancestors}, ancestor_id, descendant_id) do
    ancestor_id in Map.get(ancestors, descendant_id, [])
  end

  @doc false
  # A compound state has children to default-enter or contain a history
  # pseudo-state under (checks 5 and 7 in later phases). This is a
  # validator-local convenience, not an Appendix D predicate: ADR-0002 puts
  # `is_compound_state?` and friends on the Machine, and this function must
  # not be mistaken for a second home for them.
  @spec compound?(state :: State.t()) :: boolean()
  def compound?(%State{kind: kind, states: states}) do
    kind in [:state, :parallel] and states != []
  end

  defp walk(states, parent, ancestor_ids) do
    Enum.reduce(states, {%{}, %{}, %{}, []}, fn state,
                                                {states_map, ancestors, parents, transitions} ->
      states_map = put_named(states_map, state)
      ancestors = if state.id, do: Map.put(ancestors, state.id, ancestor_ids), else: ancestors
      parents = Map.put(parents, state, parent)
      transitions = transitions ++ own_transitions(state)

      child_ancestor_ids = if state.id, do: ancestor_ids ++ [state.id], else: ancestor_ids

      {child_states, child_ancestors, child_parents, child_transitions} =
        walk(state.states, state, child_ancestor_ids)

      {
        Map.merge(states_map, child_states),
        Map.merge(ancestors, child_ancestors),
        Map.merge(parents, child_parents),
        transitions ++ child_transitions
      }
    end)
  end

  defp put_named(states_map, %State{id: nil}), do: states_map
  defp put_named(states_map, %State{id: id} = state), do: Map.put(states_map, id, state)

  defp own_transitions(%State{kind: :history} = state) do
    Enum.map(state.transitions, &{&1, {:history, state}})
  end

  defp own_transitions(%State{} = state) do
    plain = Enum.map(state.transitions, &{&1, {:plain, state}})

    initial =
      case state.initial_element do
        nil -> []
        initial -> Enum.map(initial.transitions, &{&1, {:initial, state}})
      end

    plain ++ initial
  end
end
