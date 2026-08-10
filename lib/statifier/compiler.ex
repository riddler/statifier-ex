defmodule Statifier.Compiler do
  @moduledoc """
  The fourth arrow of the parser pipeline: a validated `%Statifier.Document{}`
  in, `{:ok, %Statifier.Machine{}} | {:error, [Statifier.Compiler.Error.t()]}`
  out (`docs/architecture.md:47-51`). Nothing downstream of this pass ever
  sees a `%Statifier.Document{}` again - the interpreter accepts only a
  `Machine` (`docs/architecture.md` principle 4).

  This phase interns every state to a flat, document-order tuple with parent
  pointers and self-inclusive descendant ranges (ADR-0005), resolves every
  `initial` to indexes, compiles every `<transition>` element - including an
  `<initial>` element's own transition and a `:history` state's default -
  into `Statifier.Machine.Transition` via its own transition pass, and
  compiles every executable-content node reachable through `onentry`,
  `onexit`, or a transition's own content into `Statifier.Machine.Content`,
  plus every `:final` state's `<donedata>` into `Statifier.Machine.Donedata`,
  via its own executable-content pass.

  ## One walk, not two (states); a real second pass (transitions, content,
  donedata)

  The "numbering walk" and "reference resolution" are, for `initial`
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
  and `c_index` assignment themselves *are* done inline, in the same walk
  that numbers states - each state's own `<onentry>`/`<onexit>` content, then
  its own transitions (its plain transitions, then its `<initial>` element's
  transition, in that order - `:history`'s own transitions are its default)
  and each transition's own content, are assigned dense index values the
  moment the state itself is visited, before the walk descends into that
  state's children - mirroring how the state's own `index` is assigned
  before its children are numbered, and matching the source's own
  `onentry*, onexit*, transition*, initial?` element order (spec 3.3-3.9).
  That is enough to keep every `t_index`/`c_index` dense and correctly
  interleaved in document order without a second walk. What genuinely waits
  for the whole walk to finish is turning each transition's raw target id
  list into resolved indexes and compiling every expression (a transition's
  `cond`, a `<log expr=...>`, a `<content>`'s folded value) - all of that
  needs either the complete `id_to_index` or nothing but the raw node
  itself, so `build_transitions/3`, `build_contents/2`, and
  `build_donedata_map/1` each run once, after `walk_siblings/4` returns.
  Their errors accumulate together, sorted by `location.start_offset`,
  mirroring `Statifier.Lowering.finalize/2`
  (`lib/statifier/lowering.ex:137-141`) - a document with a bad `cond` on one
  transition and a bad `<log expr=...>` elsewhere reports both.

  All of the walk's mutable state - `id_to_index`, the states accumulator,
  the next unused `t_index`/`c_index`, the transitions/contents/donedata
  accumulators - travels together as one `acc()` map, rather than as seven
  positional arguments: `Credo.Check.Refactor.FunctionArity`'s limit is 8,
  and a numbering walk that also assigns `c_index` genuinely needs more
  independent pieces of state than that once each is its own argument.
  """

  alias Statifier.Compiler.Error
  alias Statifier.Compiler.Expressions
  alias Statifier.Document
  alias Statifier.Document.Block, as: DBlock
  alias Statifier.Document.Content, as: DContent
  alias Statifier.Document.Donedata, as: DDonedata
  alias Statifier.Document.Initial
  alias Statifier.Document.Log, as: DLog
  alias Statifier.Document.Raise, as: DRaise
  alias Statifier.Document.State, as: DState
  alias Statifier.Document.Transition, as: DTransition
  alias Statifier.Machine
  alias Statifier.Machine.Block, as: MBlock
  alias Statifier.Machine.Content, as: MContent
  alias Statifier.Machine.Content.Log, as: MLog
  alias Statifier.Machine.Content.Raise, as: MRaise
  alias Statifier.Machine.Donedata, as: MDonedata
  alias Statifier.Machine.State, as: MState
  alias Statifier.Machine.Transition, as: MTransition
  alias Statifier.Parser.Location

  @typedoc """
  The numbering walk's threaded state (see moduledoc). `id_to_index` and
  `states_acc` belong to the interning pass; `t_next`/`transitions_acc` to
  the transition pass; `c_next`/`contents_acc`/`donedata_acc` to the
  executable-content pass.
  """
  @type acc :: %{
          id_to_index: %{optional(String.t()) => non_neg_integer()},
          states_acc: %{optional(non_neg_integer()) => MState.t()},
          t_next: non_neg_integer(),
          transitions_acc: %{optional(non_neg_integer()) => map()},
          c_next: non_neg_integer(),
          contents_acc: %{optional(non_neg_integer()) => DRaise.t() | DLog.t()},
          donedata_acc: %{optional(non_neg_integer()) => DDonedata.t()}
        }

  @spec compile(document :: Document.t()) :: {:ok, Machine.t()} | {:error, [Error.t()]}
  def compile(%Document{} = document) do
    acc0 = %{
      id_to_index: %{},
      states_acc: %{},
      t_next: 0,
      transitions_acc: %{},
      c_next: 0,
      contents_acc: %{},
      donedata_acc: %{}
    }

    {children, next_index, acc} = walk_siblings(document.states, 1, 0, acc0)

    root_last = next_index - 1

    root = %MState{
      index: 0,
      id: nil,
      kind: :scxml,
      parent: nil,
      last: root_last,
      children: children,
      initial: resolve_root_initial(document, children, acc.id_to_index),
      history_type: nil,
      history_children: history_children_of(children, acc.states_acc),
      location: document.location
    }

    states_acc = Map.put(acc.states_acc, 0, root)

    transitions_result = build_transitions(acc.transitions_acc, acc.t_next, acc.id_to_index)
    contents_result = build_contents(acc.contents_acc, acc.c_next)
    donedata_result = build_donedata_map(acc.donedata_acc)

    errors =
      [transitions_result, contents_result, donedata_result]
      |> Enum.flat_map(fn
        {:error, errors} -> errors
        {:ok, _value} -> []
      end)
      |> Enum.sort_by(& &1.location.start_offset)

    case errors do
      [] ->
        {:ok, transitions} = transitions_result
        {:ok, contents} = contents_result
        {:ok, donedata_map} = donedata_result

        states =
          0..root_last
          |> Enum.map(fn index -> with_donedata(Map.fetch!(states_acc, index), donedata_map) end)
          |> List.to_tuple()

        machine = %Machine{
          states: states,
          id_to_index: acc.id_to_index,
          transitions: transitions,
          contents: contents,
          name: document.name,
          datamodel: document.datamodel,
          binding: document.binding,
          location: document.location
        }

        {:ok, machine}

      errors ->
        {:error, errors}
    end
  end

  @spec with_donedata(mstate :: MState.t(), donedata_map :: %{non_neg_integer() => MDonedata.t()}) ::
          MState.t()
  defp with_donedata(%MState{index: index} = mstate, donedata_map) do
    case Map.fetch(donedata_map, index) do
      {:ok, donedata} -> %{mstate | donedata: donedata}
      :error -> mstate
    end
  end

  # Depth-first, document order. `next_index` is the next unused state index
  # on entry; returns the sibling group's own state indexes (in source
  # order), the next unused state index once the whole group and its
  # subtrees are numbered, and the threaded `acc()` grown with everything the
  # group's subtrees contributed.
  #
  # `last` is never computed separately from this traversal - a state's
  # `last` is `next_index - 1` at the point its own subtree finishes, which
  # is exactly the recursion's return value.
  @spec walk_siblings(
          siblings :: [DState.t()],
          next_index :: non_neg_integer(),
          parent_index :: non_neg_integer(),
          acc :: acc()
        ) :: {[non_neg_integer()], non_neg_integer(), acc()}
  defp walk_siblings([], next_index, _parent_index, acc), do: {[], next_index, acc}

  defp walk_siblings([dstate | rest], next_index, parent_index, acc) do
    index = next_index

    {onentry, onexit, own_transitions, initial_transition, history_default, acc} =
      assign_own_content_and_transitions(dstate, index, acc)

    acc = %{acc | donedata_acc: maybe_put_donedata(acc.donedata_acc, index, dstate.donedata)}

    {children, next_after_subtree, acc} = walk_siblings(dstate.states, index + 1, index, acc)

    last = next_after_subtree - 1

    mstate = %MState{
      index: index,
      id: dstate.id,
      kind: dstate.kind,
      parent: parent_index,
      last: last,
      children: children,
      initial: resolve_initial(dstate, children, acc.id_to_index),
      history_type: dstate.history_type,
      history_children: history_children_of(children, acc.states_acc),
      transitions: own_transitions,
      onentry: onentry,
      onexit: onexit,
      initial_transition: initial_transition,
      history_default: history_default,
      location: dstate.location
    }

    acc = %{
      acc
      | id_to_index: maybe_put_id(acc.id_to_index, dstate.id, index),
        states_acc: Map.put(acc.states_acc, index, mstate)
    }

    {siblings, final_next, acc} = walk_siblings(rest, next_after_subtree, parent_index, acc)

    {[index | siblings], final_next, acc}
  end

  # A state's own compiled `onentry`/`onexit` blocks and `t_index`-bearing
  # transitions, assigned the moment the state itself is visited - before the
  # walk descends into its children - so a state's own content and
  # transitions always sort before any of its descendants'. Assignment order
  # mirrors the source's own `onentry*, onexit*, transition*, initial?`
  # element order (spec 3.3-3.9):
  # onentry content, then onexit content, then this state's own transitions
  # (and each transition's own content, assigned at the point that
  # transition itself is numbered). `:history`'s own transitions are its
  # default candidate(s), never selectable; every other kind's own
  # transitions are its plain (selectable) ones, followed by its
  # `<initial>` element's transition, if it has one (validator check 4
  # guarantees at most one form is present, and
  # `Statifier.Validator.Checks.DefaultTransition` guarantees exactly one
  # transition inside a written `<initial>`/`<history>`, so `List.first/1`
  # on an already-validated document never silently drops a sibling).
  @spec assign_own_content_and_transitions(
          dstate :: DState.t(),
          source_index :: non_neg_integer(),
          acc :: acc()
        ) ::
          {[MBlock.t()], [MBlock.t()], [non_neg_integer()], non_neg_integer() | nil,
           non_neg_integer() | nil, acc()}
  defp assign_own_content_and_transitions(%DState{kind: :history} = dstate, source_index, acc) do
    {onentry, acc} = assign_blocks(dstate.onentry, acc)
    {onexit, acc} = assign_blocks(dstate.onexit, acc)
    {t_indexes, acc} = assign_transitions(dstate.transitions, source_index, acc)

    {onentry, onexit, [], nil, List.first(t_indexes), acc}
  end

  defp assign_own_content_and_transitions(%DState{} = dstate, source_index, acc) do
    {onentry, acc} = assign_blocks(dstate.onentry, acc)
    {onexit, acc} = assign_blocks(dstate.onexit, acc)
    {plain_t_indexes, acc} = assign_transitions(dstate.transitions, source_index, acc)

    {initial_t_indexes, acc} =
      assign_transitions(initial_element_transitions(dstate.initial_element), source_index, acc)

    {onentry, onexit, plain_t_indexes, List.first(initial_t_indexes), nil, acc}
  end

  @spec initial_element_transitions(initial_element :: Initial.t() | nil) :: [DTransition.t()]
  defp initial_element_transitions(nil), do: []
  defp initial_element_transitions(%Initial{transitions: transitions}), do: transitions

  # Assigns dense, ascending `t_index` values to `transitions`, in list
  # (source) order, recording each raw transition, its owning state's index,
  # and its own executable content's assigned `c_index` list for
  # `build_transitions/3` to resolve later. Returns the assigned `t_index`es
  # in the same order as `transitions`.
  @spec assign_transitions(
          transitions :: [DTransition.t()],
          source_index :: non_neg_integer(),
          acc :: acc()
        ) :: {[non_neg_integer()], acc()}
  defp assign_transitions(transitions, source_index, acc) do
    {t_indexes, acc} =
      Enum.reduce(transitions, {[], acc}, fn transition, {t_indexes, acc} ->
        {content_indexes, acc} = assign_content_nodes(transition.content, acc)
        t_index = acc.t_next

        entry = %{transition: transition, source: source_index, content: content_indexes}

        acc = %{
          acc
          | t_next: t_index + 1,
            transitions_acc: Map.put(acc.transitions_acc, t_index, entry)
        }

        {[t_index | t_indexes], acc}
      end)

    {Enum.reverse(t_indexes), acc}
  end

  # Assigns dense, ascending `c_index` values to `blocks` (a state's own
  # `onentry` or `onexit` list), in source order, building each block's
  # compiled `Statifier.Machine.Block.t()` with the `c_index` list it was
  # assigned. A block's own `location` needs no compilation - only its
  # content nodes do, deferred to `build_contents/2`.
  @spec assign_blocks(blocks :: [DBlock.t()], acc :: acc()) :: {[MBlock.t()], acc()}
  defp assign_blocks(blocks, acc) do
    {mblocks, acc} =
      Enum.reduce(blocks, {[], acc}, fn block, {mblocks, acc} ->
        {content_indexes, acc} = assign_content_nodes(block.content, acc)
        mblock = %MBlock{location: block.location, content: content_indexes}
        {[mblock | mblocks], acc}
      end)

    {Enum.reverse(mblocks), acc}
  end

  # Assigns dense, ascending `c_index` values to `nodes` (a flat
  # `[Statifier.Document.Raise.t() | Statifier.Document.Log.t()]`, either a
  # block's own content or a transition's own content), in source order,
  # recording each raw node for `build_contents/2` to compile later. Returns
  # the assigned `c_index`es in the same order as `nodes`.
  @spec assign_content_nodes(nodes :: [DRaise.t() | DLog.t()], acc :: acc()) ::
          {[non_neg_integer()], acc()}
  defp assign_content_nodes(nodes, acc) do
    {c_indexes, acc} =
      Enum.reduce(nodes, {[], acc}, fn node, {c_indexes, acc} ->
        c_index = acc.c_next

        acc = %{
          acc
          | c_next: c_index + 1,
            contents_acc: Map.put(acc.contents_acc, c_index, node)
        }

        {[c_index | c_indexes], acc}
      end)

    {Enum.reverse(c_indexes), acc}
  end

  @spec maybe_put_donedata(
          donedata_acc :: map(),
          index :: non_neg_integer(),
          donedata :: DDonedata.t() | nil
        ) :: map()
  defp maybe_put_donedata(donedata_acc, _index, nil), do: donedata_acc

  defp maybe_put_donedata(donedata_acc, index, %DDonedata{} = donedata),
    do: Map.put(donedata_acc, index, donedata)

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
  # resolve), and `:final`/`:history` are never compound-entered at all.
  # Validator check 7 already rejects the one illegal default case (a
  # leading `:history` child), so the default here needs no re-checking.
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

  # The transition reference-resolution pass: with `id_to_index` complete,
  # every transition's raw target id list becomes resolved indexes and every
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

    case collect(results) do
      {:ok, list} -> {:ok, List.to_tuple(list)}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec build_transition(
          t_index :: non_neg_integer(),
          entry :: %{
            transition: DTransition.t(),
            source: non_neg_integer(),
            content: [non_neg_integer()]
          },
          id_to_index :: map()
        ) :: {:ok, MTransition.t()} | {:error, Error.t()}
  defp build_transition(
         t_index,
         %{transition: transition, source: source, content: content},
         id_to_index
       ) do
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
           content: content,
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

  # Compiles every collected executable-content node into
  # `Statifier.Machine.Content.t()`, dense from `c_index` 0. Errors
  # accumulate the same way `build_transitions/3`'s do.
  @spec build_contents(contents_acc :: map(), c_count :: non_neg_integer()) ::
          {:ok, tuple()} | {:error, [Error.t()]}
  defp build_contents(_contents_acc, 0), do: {:ok, {}}

  defp build_contents(contents_acc, c_count) do
    results =
      Enum.map(0..(c_count - 1), fn c_index ->
        build_content_node(c_index, Map.fetch!(contents_acc, c_index))
      end)

    case collect(results) do
      {:ok, list} -> {:ok, List.to_tuple(list)}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec build_content_node(c_index :: non_neg_integer(), node :: DRaise.t() | DLog.t()) ::
          {:ok, MContent.t()} | {:error, Error.t()}
  defp build_content_node(c_index, %DRaise{event: event, location: location}) do
    {:ok, %MRaise{c_index: c_index, event: event, location: location}}
  end

  defp build_content_node(c_index, %DLog{expr: nil, label: label, location: location}) do
    {:ok, %MLog{c_index: c_index, label: label, expr: nil, location: location}}
  end

  defp build_content_node(c_index, %DLog{expr: source, label: label, location: location} = log) do
    case Expressions.compile(source, {:content, c_index}, expr_location(log)) do
      {:ok, expr} ->
        {:ok,
         %MLog{
           c_index: c_index,
           label: label,
           expr: expr,
           location: location,
           expr_location: expr_location(log)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # `attribute_locations[:expr]`'s value span when the author wrote `expr`
  # and it carries a recorded span, the `<log>` node's own `location`
  # otherwise (`Statifier.Compiler.Expressions.compile/3`'s "caller's
  # choice" contract) - mirrors `cond_location/1`.
  @spec expr_location(log :: DLog.t()) :: Location.t()
  defp expr_location(%DLog{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :expr, location)
  end

  # Compiles every `:final` state's own `<donedata>` into
  # `Statifier.Machine.Donedata.t()`. No `c_index` is assigned - `<donedata>`'s
  # content is not executable content, never appears in a block, and no
  # `execute_block` ever runs it, so `donedata_acc` is keyed by owning state
  # index, not a dense counter, and this pass has no density property to
  # assert - only that every entry compiles.
  @spec build_donedata_map(donedata_acc :: %{non_neg_integer() => DDonedata.t()}) ::
          {:ok, %{non_neg_integer() => MDonedata.t()}} | {:error, [Error.t()]}
  defp build_donedata_map(donedata_acc) do
    results =
      Enum.map(donedata_acc, fn {index, donedata} ->
        case build_donedata(index, donedata) do
          {:ok, mdonedata} -> {:ok, {index, mdonedata}}
          {:error, error} -> {:error, error}
        end
      end)

    case collect(results) do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec build_donedata(index :: non_neg_integer(), donedata :: DDonedata.t()) ::
          {:ok, MDonedata.t()} | {:error, Error.t()}
  defp build_donedata(_index, %DDonedata{location: location, content: nil}) do
    {:ok, %MDonedata{location: location, expr: nil, expr_location: nil}}
  end

  defp build_donedata(index, %DDonedata{location: location, content: %DContent{} = content}) do
    case build_content_expr(content, {:donedata, index}) do
      {:ok, expr} ->
        {:ok,
         %MDonedata{
           location: location,
           expr: expr,
           expr_location: content_expr_location(content)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # `<content>`'s folded value: the compiled arm from a written `expr`
  # attribute, the static arm from its text body otherwise -
  # validator check 9 (`Statifier.Validator.Checks.Content`) already
  # guarantees the two are never both present.
  @spec build_content_expr(content :: DContent.t(), owner :: Expressions.owner_ref()) ::
          {:ok, Machine.expr()} | {:error, Error.t()}
  defp build_content_expr(%DContent{expr: nil, text: text}, _owner),
    do: {:ok, Expressions.static(text)}

  defp build_content_expr(%DContent{expr: source} = content, owner) do
    Expressions.compile(source, owner, content_expr_location(content))
  end

  # The compiled arm's diagnostic span is `attribute_locations[:expr]`'s
  # value span when the author wrote `expr` (mirrors `cond_location/1` and
  # `expr_location/1`). The static arm's is the `<content>` node's own
  # `location`: `Content.text` has no span of its own by design
  # (`lib/statifier/document/content.ex:17-21`).
  @spec content_expr_location(content :: DContent.t()) :: Location.t()
  defp content_expr_location(%DContent{expr: nil, location: location}), do: location

  defp content_expr_location(%DContent{
         expr: _source,
         attribute_locations: attribute_locations,
         location: location
       }) do
    Map.get(attribute_locations, :expr, location)
  end

  # Collects a list of `{:ok, value} | {:error, Error.t()}` results into
  # `{:ok, [value]} | {:error, [Error.t()]}`, sorted by
  # `location.start_offset` on the error path - the one shape
  # `build_transitions/3`, `build_contents/2`, and `build_donedata_map/1`
  # all need.
  @spec collect(results :: [{:ok, term()} | {:error, Error.t()}]) ::
          {:ok, [term()]} | {:error, [Error.t()]}
  defp collect(results) do
    errors =
      results
      |> Enum.filter(&match?({:error, _error}, &1))
      |> Enum.map(fn {:error, error} -> error end)
      |> Enum.sort_by(& &1.location.start_offset)

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      errors -> {:error, errors}
    end
  end
end
