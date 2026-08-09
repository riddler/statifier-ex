defmodule Statifier.Compiler do
  @moduledoc """
  The fourth arrow of the parser pipeline: a validated `%Statifier.Document{}`
  in, `{:ok, %Statifier.Machine{}} | {:error, [Statifier.Compiler.Error.t()]}`
  out (`docs/architecture.md:47-51`). Nothing downstream of this pass ever
  sees a `%Statifier.Document{}` again - the interpreter accepts only a
  `Machine` (`docs/architecture.md` principle 4).

  This phase interns every state to a flat, document-order tuple with parent
  pointers and self-inclusive descendant ranges (ADR-0005), and resolves
  every `initial` to indexes. Transitions, executable content, and
  expressions are not compiled here - `Statifier.Machine.State.transitions`,
  `.onentry`, `.onexit`, `.initial_transition`, `.history_default`, and
  `.donedata` are declared but stay at their empty defaults until Phases 4
  and 5, and `machine.transitions` / `machine.contents` are empty tuples
  until then.

  ## One walk, not two

  The plan's "numbering walk" and "reference resolution" are, for `initial`
  specifically, one traversal rather than two: a state's `initial` can only
  legally name a descendant of that state (validator checks 3 and 7), and
  descendants are always finished - numbered, and their own ids entered into
  `id_to_index` - before their ancestor is, because this walk is post-order
  on the way out of each subtree. So `id_to_index` already holds every id
  `resolve_initial/3` could legally need by the time it runs, and resolving
  inline avoids threading the raw `Statifier.Document.State` tree through a
  second pass just to re-ask questions the first pass already had the answer
  to. (Transition target resolution in Phase 4 cannot make the same move -
  a transition's target is not constrained to be a descendant of its source
  - so that phase's reference resolution genuinely waits for the whole walk
  to finish.)
  """

  alias Statifier.Compiler.Error
  alias Statifier.Document
  alias Statifier.Document.Initial
  alias Statifier.Document.State, as: DState
  alias Statifier.Machine
  alias Statifier.Machine.State, as: MState

  @spec compile(document :: Document.t()) :: {:ok, Machine.t()} | {:error, [Error.t()]}
  def compile(%Document{} = document) do
    {children, next_index, id_to_index, states_acc} =
      walk_siblings(document.states, 1, 0, %{}, %{})

    root_last = next_index - 1

    root = %MState{
      index: 0,
      id: nil,
      kind: :scxml,
      parent: nil,
      last: root_last,
      children: children,
      initial: resolve_root_initial(document, children, id_to_index),
      history_type: nil,
      history_children: history_children_of(children, states_acc),
      location: document.location
    }

    states =
      0..root_last
      |> Enum.map(fn
        0 -> root
        index -> Map.fetch!(states_acc, index)
      end)
      |> List.to_tuple()

    machine = %Machine{
      states: states,
      id_to_index: id_to_index,
      transitions: {},
      contents: {},
      name: document.name,
      datamodel: document.datamodel,
      binding: document.binding,
      location: document.location
    }

    {:ok, machine}
  end

  # Depth-first, document order. `next_index` is the next unused index on
  # entry; returns the sibling group's own indexes (in source order), the
  # next unused index once the whole group and its subtrees are numbered,
  # the id map grown with every named descendant, and the states accumulator
  # grown with every compiled state in the group's subtrees.
  #
  # `last` is never computed separately from this traversal - a state's
  # `last` is `next_index - 1` at the point its own subtree finishes, which
  # is exactly the recursion's return value (plan Implementation Approach).
  @spec walk_siblings(
          siblings :: [DState.t()],
          next_index :: non_neg_integer(),
          parent_index :: non_neg_integer(),
          id_to_index :: %{optional(String.t()) => non_neg_integer()},
          states_acc :: %{optional(non_neg_integer()) => MState.t()}
        ) :: {[non_neg_integer()], non_neg_integer(), map(), map()}
  defp walk_siblings([], next_index, _parent_index, id_to_index, states_acc) do
    {[], next_index, id_to_index, states_acc}
  end

  defp walk_siblings([dstate | rest], next_index, parent_index, id_to_index, states_acc) do
    index = next_index

    {children, next_after_subtree, id_to_index, states_acc} =
      walk_siblings(dstate.states, index + 1, index, id_to_index, states_acc)

    last = next_after_subtree - 1

    mstate = %MState{
      index: index,
      id: dstate.id,
      kind: dstate.kind,
      parent: parent_index,
      last: last,
      children: children,
      initial: resolve_initial(dstate, children, id_to_index),
      history_type: dstate.history_type,
      history_children: history_children_of(children, states_acc),
      location: dstate.location
    }

    id_to_index = maybe_put_id(id_to_index, dstate.id, index)
    states_acc = Map.put(states_acc, index, mstate)

    {siblings, final_next, id_to_index, states_acc} =
      walk_siblings(rest, next_after_subtree, parent_index, id_to_index, states_acc)

    {[index | siblings], final_next, id_to_index, states_acc}
  end

  @spec maybe_put_id(id_to_index :: map(), id :: String.t() | nil, index :: non_neg_integer()) ::
          map()
  defp maybe_put_id(id_to_index, nil, _index), do: id_to_index
  defp maybe_put_id(id_to_index, "", _index), do: id_to_index
  defp maybe_put_id(id_to_index, id, index), do: Map.put(id_to_index, id, index)

  # A compound/parallel state's own direct `:history` children - already-
  # compiled at this point (children are finished before their parent in
  # this post-order walk), so this is a lookup, never a scan of the subtree.
  @spec history_children_of(children :: [non_neg_integer()], states_acc :: map()) :: [
          non_neg_integer()
        ]
  defp history_children_of(children, states_acc) do
    Enum.filter(children, fn child_index ->
      Map.fetch!(states_acc, child_index).kind == :history
    end)
  end

  # `initial` resolution (spec 3.3), in precedence order: the `initial`
  # attribute, the `<initial>` element's transition target, then the
  # first-document-order-child default. Only `:state` resolves anything - a
  # `:parallel` enters every region simultaneously (no positional default to
  # resolve), and `:final`/`:history` are never compound-entered at all
  # (plan Changes Required #4). Validator check 7 already rejects the one
  # illegal default case (a leading `:history` child), so the default here
  # needs no re-checking.
  @spec resolve_initial(
          dstate :: DState.t(),
          children :: [non_neg_integer()],
          id_to_index :: map()
        ) :: [non_neg_integer()]
  defp resolve_initial(%DState{kind: :state, initial: initial}, _children, id_to_index)
       when initial != [] do
    Enum.map(initial, &Map.fetch!(id_to_index, &1))
  end

  defp resolve_initial(
         %DState{kind: :state, initial_element: %Initial{transitions: [transition]}},
         _children,
         id_to_index
       ) do
    Enum.map(transition.target, &Map.fetch!(id_to_index, &1))
  end

  defp resolve_initial(%DState{kind: :state}, children, _id_to_index) do
    case children do
      [] -> []
      [first | _rest] -> [first]
    end
  end

  defp resolve_initial(%DState{}, _children, _id_to_index), do: []

  # The `:scxml` root's own `initial` (spec 3.2/3.3): the root has only the
  # attribute form (`Statifier.Document` carries no `initial_element`), so
  # its precedence is two-way rather than three-way.
  @spec resolve_root_initial(
          document :: Document.t(),
          children :: [non_neg_integer()],
          id_to_index :: map()
        ) :: [non_neg_integer()]
  defp resolve_root_initial(%Document{initial: initial}, _children, id_to_index)
       when initial != [] do
    Enum.map(initial, &Map.fetch!(id_to_index, &1))
  end

  defp resolve_root_initial(%Document{}, children, _id_to_index) do
    case children do
      [] -> []
      [first | _rest] -> [first]
    end
  end
end
