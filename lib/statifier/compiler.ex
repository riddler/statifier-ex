defmodule Statifier.Compiler do
  @moduledoc """
  The fourth arrow of the parser pipeline: a validated `%Statifier.Document{}`
  in, `{:ok, %Statifier.Machine{}} | {:error, [Statifier.Compiler.Error.t()]}`
  out (`docs/architecture.md:47-51`). Nothing downstream of this pass ever
  sees a `%Statifier.Document{}` again - the interpreter accepts only a
  `Machine` (`docs/architecture.md` principle 4).

  This phase interns every state to a flat, document-order tuple with parent
  pointers and self-inclusive descendant ranges (ADR-0005), resolves every
  `initial` to indexes, and (Phase 4) compiles every `<transition>` element -
  including an `<initial>` element's own transition and a `:history` state's
  default - into `Statifier.Machine.Transition`, assigning each a dense
  `t_index`. Executable content is not compiled here -
  `Statifier.Machine.State.onentry`, `.onexit`, and `.donedata`, and
  `Statifier.Machine.Transition.content`, are declared but stay at their
  empty defaults until Phase 5, and `machine.contents` is an empty tuple
  until then.

  ## One walk, not two (states); a real second pass (transitions)

  The plan's "numbering walk" and "reference resolution" are, for `initial`
  specifically, one traversal rather than two: a state's `initial` can only
  legally name a descendant of that state (validator checks 3 and 7), and
  descendants are always finished - numbered, and their own ids entered into
  `id_to_index` - before their ancestor is, because this walk is post-order
  on the way out of each subtree. So `id_to_index` already holds every id
  `resolve_initial/3` could legally need by the time it runs, and resolving
  inline avoids threading the raw `Statifier.Document.State` tree through a
  second pass just to re-ask questions the first pass already had the answer
  to.

  Transition **target** resolution cannot make the same move: a transition's
  target is not constrained to be a descendant of its source, so it can be a
  forward reference to a state the walk has not reached yet
  (`id_to_index` incomplete at the point the transition is visited). `t_index`
  assignment itself *is* done inline, in the same walk that numbers states -
  each state's own transitions (its plain transitions, then its `<initial>`
  element's transition, in that order - `:history`'s own transitions are its
  default) are assigned `t_index` values the moment the state itself is
  visited, before the walk descends into that state's children, mirroring
  how the state's own `index` is assigned before its children are numbered.
  That is enough to keep every `t_index` dense and to keep two different
  states' transitions correctly interleaved in document order without a
  second walk. What genuinely waits for the whole walk to finish is turning
  each transition's raw target id list into resolved indexes and compiling
  its `cond` - both need the complete `id_to_index`, so `build_transitions/3`
  runs once, after `walk_siblings/7` returns.
  """

  alias Statifier.Compiler.Error
  alias Statifier.Compiler.Expressions
  alias Statifier.Document
  alias Statifier.Document.Initial
  alias Statifier.Document.State, as: DState
  alias Statifier.Document.Transition, as: DTransition
  alias Statifier.Machine
  alias Statifier.Machine.State, as: MState
  alias Statifier.Machine.Transition, as: MTransition
  alias Statifier.Parser.Location

  @spec compile(document :: Document.t()) :: {:ok, Machine.t()} | {:error, [Error.t()]}
  def compile(%Document{} = document) do
    {children, next_index, id_to_index, states_acc, t_next, transitions_acc} =
      walk_siblings(document.states, 1, 0, %{}, %{}, 0, %{})

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

    case build_transitions(transitions_acc, t_next, id_to_index) do
      {:ok, transitions} ->
        machine = %Machine{
          states: states,
          id_to_index: id_to_index,
          transitions: transitions,
          contents: {},
          name: document.name,
          datamodel: document.datamodel,
          binding: document.binding,
          location: document.location
        }

        {:ok, machine}

      {:error, errors} ->
        {:error, errors}
    end
  end

  # Depth-first, document order. `next_index` is the next unused state index
  # on entry, `t_next` the next unused `t_index`; returns the sibling
  # group's own state indexes (in source order), the next unused state index
  # once the whole group and its subtrees are numbered, the id map grown
  # with every named descendant, the states accumulator grown with every
  # compiled state in the group's subtrees, the next unused `t_index` once
  # every transition in the group's subtrees is assigned, and the
  # transitions accumulator (`t_index => %{transition:, source:}`) grown
  # with every one of them.
  #
  # `last` is never computed separately from this traversal - a state's
  # `last` is `next_index - 1` at the point its own subtree finishes, which
  # is exactly the recursion's return value (plan Implementation Approach).
  @spec walk_siblings(
          siblings :: [DState.t()],
          next_index :: non_neg_integer(),
          parent_index :: non_neg_integer(),
          id_to_index :: %{optional(String.t()) => non_neg_integer()},
          states_acc :: %{optional(non_neg_integer()) => MState.t()},
          t_next :: non_neg_integer(),
          transitions_acc :: %{optional(non_neg_integer()) => map()}
        ) :: {[non_neg_integer()], non_neg_integer(), map(), map(), non_neg_integer(), map()}
  defp walk_siblings(
         [],
         next_index,
         _parent_index,
         id_to_index,
         states_acc,
         t_next,
         transitions_acc
       ) do
    {[], next_index, id_to_index, states_acc, t_next, transitions_acc}
  end

  defp walk_siblings(
         [dstate | rest],
         next_index,
         parent_index,
         id_to_index,
         states_acc,
         t_next,
         transitions_acc
       ) do
    index = next_index

    {own_transitions, initial_transition, history_default, t_next, transitions_acc} =
      assign_own_transitions(dstate, index, t_next, transitions_acc)

    {children, next_after_subtree, id_to_index, states_acc, t_next, transitions_acc} =
      walk_siblings(
        dstate.states,
        index + 1,
        index,
        id_to_index,
        states_acc,
        t_next,
        transitions_acc
      )

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
      transitions: own_transitions,
      initial_transition: initial_transition,
      history_default: history_default,
      location: dstate.location
    }

    id_to_index = maybe_put_id(id_to_index, dstate.id, index)
    states_acc = Map.put(states_acc, index, mstate)

    {siblings, final_next, id_to_index, states_acc, t_next, transitions_acc} =
      walk_siblings(
        rest,
        next_after_subtree,
        parent_index,
        id_to_index,
        states_acc,
        t_next,
        transitions_acc
      )

    {[index | siblings], final_next, id_to_index, states_acc, t_next, transitions_acc}
  end

  # A state's own `t_index`-bearing transitions, assigned the moment the
  # state itself is visited - before the walk descends into its children -
  # so a state's transitions always sort before any of its descendants'
  # (plan Decision 9). `:history`'s own transitions are its default
  # candidate(s), never selectable; every other kind's own transitions are
  # its plain (selectable) ones, followed by its `<initial>` element's
  # transition, if it has one (validator check 4 guarantees at most one
  # form is present, and `Statifier.Validator.Checks.DefaultTransition`
  # guarantees exactly one transition inside a written `<initial>`/
  # `<history>`, so `List.first/1` on an already-validated document never
  # silently drops a sibling).
  @spec assign_own_transitions(
          dstate :: DState.t(),
          source_index :: non_neg_integer(),
          t_next :: non_neg_integer(),
          transitions_acc :: map()
        ) ::
          {[non_neg_integer()], non_neg_integer() | nil, non_neg_integer() | nil,
           non_neg_integer(), map()}
  defp assign_own_transitions(
         %DState{kind: :history} = dstate,
         source_index,
         t_next,
         transitions_acc
       ) do
    {t_indexes, t_next, transitions_acc} =
      assign_transitions(dstate.transitions, source_index, t_next, transitions_acc)

    {[], nil, List.first(t_indexes), t_next, transitions_acc}
  end

  defp assign_own_transitions(%DState{} = dstate, source_index, t_next, transitions_acc) do
    {plain_t_indexes, t_next, transitions_acc} =
      assign_transitions(dstate.transitions, source_index, t_next, transitions_acc)

    {initial_t_indexes, t_next, transitions_acc} =
      assign_transitions(
        initial_element_transitions(dstate.initial_element),
        source_index,
        t_next,
        transitions_acc
      )

    {plain_t_indexes, List.first(initial_t_indexes), nil, t_next, transitions_acc}
  end

  @spec initial_element_transitions(initial_element :: Initial.t() | nil) :: [DTransition.t()]
  defp initial_element_transitions(nil), do: []
  defp initial_element_transitions(%Initial{transitions: transitions}), do: transitions

  # Assigns dense, ascending `t_index` values to `transitions`, in list
  # (source) order, recording each raw transition and its owning state's
  # index for `build_transitions/3` to resolve later. Returns the assigned
  # `t_index`es in the same order as `transitions`.
  @spec assign_transitions(
          transitions :: [DTransition.t()],
          source_index :: non_neg_integer(),
          t_next :: non_neg_integer(),
          transitions_acc :: map()
        ) :: {[non_neg_integer()], non_neg_integer(), map()}
  defp assign_transitions(transitions, source_index, t_next, transitions_acc) do
    {t_indexes, t_next, transitions_acc} =
      Enum.reduce(transitions, {[], t_next, transitions_acc}, fn transition,
                                                                 {t_indexes, t_next, acc} ->
        acc = Map.put(acc, t_next, %{transition: transition, source: source_index})
        {[t_next | t_indexes], t_next + 1, acc}
      end)

    {Enum.reverse(t_indexes), t_next, transitions_acc}
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

  # The transition reference-resolution pass (plan Implementation Approach
  # step 2, applied to transitions): with `id_to_index` complete, every
  # transition's raw target id list becomes resolved indexes and every
  # `cond` is compiled. Errors accumulate rather than short-circuit and are
  # sorted by `location.start_offset` before returning, mirroring
  # `Statifier.Lowering.finalize/2` (`lib/statifier/lowering.ex:137-141`) -
  # a document with two bad `cond`s on two different transitions reports
  # both.
  @spec build_transitions(
          transitions_acc :: map(),
          t_count :: non_neg_integer(),
          id_to_index :: map()
        ) :: {:ok, tuple()} | {:error, [Error.t()]}
  defp build_transitions(_transitions_acc, 0, _id_to_index), do: {:ok, {}}

  defp build_transitions(transitions_acc, t_count, id_to_index) do
    results =
      Enum.map(0..(t_count - 1), fn t_index ->
        build_transition(t_index, Map.fetch!(transitions_acc, t_index), id_to_index)
      end)

    errors =
      results
      |> Enum.filter(&match?({:error, _error}, &1))
      |> Enum.map(fn {:error, error} -> error end)
      |> Enum.sort_by(& &1.location.start_offset)

    case errors do
      [] -> {:ok, results |> Enum.map(fn {:ok, transition} -> transition end) |> List.to_tuple()}
      errors -> {:error, errors}
    end
  end

  @spec build_transition(
          t_index :: non_neg_integer(),
          entry :: %{transition: DTransition.t(), source: non_neg_integer()},
          id_to_index :: map()
        ) :: {:ok, MTransition.t()} | {:error, Error.t()}
  defp build_transition(t_index, %{transition: transition, source: source}, id_to_index) do
    case build_cond(transition, t_index) do
      {:ok, cond_expr} ->
        {:ok,
         %MTransition{
           t_index: t_index,
           source: source,
           targets: Enum.map(transition.target, &Map.fetch!(id_to_index, &1)),
           events: Enum.map(transition.event, &String.split(&1, ".")),
           cond: cond_expr,
           type: transition.type,
           content: [],
           location: transition.location,
           cond_location: cond_location(transition)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec build_cond(transition :: DTransition.t(), t_index :: non_neg_integer()) ::
          {:ok, Machine.expr() | nil} | {:error, Error.t()}
  defp build_cond(%DTransition{cond: nil}, _t_index), do: {:ok, nil}

  defp build_cond(%DTransition{cond: source} = transition, t_index) do
    Expressions.compile(source, {:transition, t_index}, cond_location(transition))
  end

  # `attribute_locations[:cond]`'s value span when the author wrote `cond`
  # and it carries a recorded span, the transition's own `location`
  # otherwise (`Statifier.Compiler.Expressions.compile/3`'s "caller's
  # choice" contract) - `nil` only when `cond` itself was never written, so
  # `cond_location` and `cond` are non-nil together.
  @spec cond_location(transition :: DTransition.t()) :: Location.t() | nil
  defp cond_location(%DTransition{cond: nil}), do: nil

  defp cond_location(%DTransition{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :cond, location)
  end
end
