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
  itself, so `build_transitions/3`, `build_contents/2`, `build_donedata_map/1`,
  and `build_data_elements/2` each run once, after `walk_siblings/4` returns.
  The first three's errors accumulate together, sorted by
  `location.start_offset`, mirroring `Statifier.Lowering.finalize/2`
  (`lib/statifier/lowering.ex:137-141`) - a document with a bad `cond` on one
  transition and a bad `<log expr=...>` elsewhere reports both.
  `build_data_elements/2` never joins that merge - a `<data expr>` that
  fails to compile is captured onto the compiled `Statifier.Machine.Data`
  node as `{:invalid, error}` rather than failing `compile/1` (Decision 2,
  `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`), so a
  document with a bad `cond` *and* a bad `<data expr>` reports only the
  `cond`'s error.

  `<data>` gets its own dense index space, `d_index`, assigned the same way
  `t_index`/`c_index` are: a state's own `<datamodel>`'s `<data>` children
  are assigned the moment the state itself is visited, before the walk
  descends into its children (`assign_data/3`). The root's own top-level
  `<datamodel>` is assigned before `walk_siblings/4` is first called, so
  top-level `<data>` occupy `d_index` 0..n-1, preceding every state-scoped
  one.

  All of the walk's mutable state - `id_to_index`, the states accumulator,
  the next unused `t_index`/`c_index`/`d_index`, the
  transitions/contents/donedata/data accumulators - travels together as one
  `acc()` map, rather than as seven-plus positional arguments:
  `Credo.Check.Refactor.FunctionArity`'s limit is 8, and a numbering walk
  that also assigns `c_index` and `d_index` genuinely needs more independent
  pieces of state than that once each is its own argument.
  """

  alias Statifier.Compiler.Error
  alias Statifier.Compiler.Expressions
  alias Statifier.Document
  alias Statifier.Document.Assign, as: DAssign
  alias Statifier.Document.Block, as: DBlock
  alias Statifier.Document.Content, as: DContent
  alias Statifier.Document.Data, as: DData
  alias Statifier.Document.Datamodel, as: DDatamodel
  alias Statifier.Document.Donedata, as: DDonedata
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.Initial
  alias Statifier.Document.Log, as: DLog
  alias Statifier.Document.Param, as: DParam
  alias Statifier.Document.Raise, as: DRaise
  alias Statifier.Document.Script, as: DScript
  alias Statifier.Document.State, as: DState
  alias Statifier.Document.Transition, as: DTransition
  alias Statifier.Machine
  alias Statifier.Machine.Block, as: MBlock
  alias Statifier.Machine.Content, as: MContent
  alias Statifier.Machine.Content.Assign, as: MAssign
  alias Statifier.Machine.Content.Foreach, as: MForeach
  alias Statifier.Machine.Content.If, as: MIf
  alias Statifier.Machine.Content.Log, as: MLog
  alias Statifier.Machine.Content.Raise, as: MRaise
  alias Statifier.Machine.Content.Script, as: MScript
  alias Statifier.Machine.Data, as: MData
  alias Statifier.Machine.Donedata, as: MDonedata
  alias Statifier.Machine.Param, as: MParam
  alias Statifier.Machine.State, as: MState
  alias Statifier.Machine.Transition, as: MTransition
  alias Statifier.Parser.Location

  @typedoc """
  The numbering walk's threaded state (see moduledoc). `id_to_index` and
  `states_acc` belong to the interning pass; `t_next`/`transitions_acc` to
  the transition pass; `c_next`/`contents_acc`/`donedata_acc` to the
  executable-content pass; `d_next`/`data_acc` to the `<data>` pass -
  `data_acc` keyed by `d_index`, each entry carrying its raw
  `%Statifier.Document.Data{}` and the index of the state whose own
  `<datamodel>` declared it, so `build_data_elements/2` can compile in
  `d_index` order and `compile/1` can later group entries back by state
  index for `with_data/2`.

  `contents_acc`'s value type is asymmetric on purpose: `<raise>`, `<log>`,
  and `<assign>` are stored raw, since none of the three has children of its
  own to number - but an `<if>` and a `<foreach>` do, so their entries carry
  the raw node alongside the `c_index` list(s) `assign_content_nodes/2`'s
  own recursion (Decision 2 of
  `docs/plans/260813-st-af3.5-if-elseif-else-conditional-executable-content.md`)
  assigned: `%{if: DIf.t(), branches: [[non_neg_integer()]]}` for an `<if>`
  (one list per branch), `%{foreach: DForeach.t(), content: [non_neg_integer()]}`
  for a `<foreach>` (one flat list, one nesting level shallower - Decision 8
  of `docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md`) - mirroring
  `transitions_acc`'s own `%{transition: ..., source: ..., content: ...}`
  shape (`:396-408`).
  """
  @type acc :: %{
          id_to_index: %{optional(String.t()) => non_neg_integer()},
          states_acc: %{optional(non_neg_integer()) => MState.t()},
          t_next: non_neg_integer(),
          transitions_acc: %{optional(non_neg_integer()) => map()},
          c_next: non_neg_integer(),
          contents_acc: %{
            optional(non_neg_integer()) =>
              DRaise.t()
              | DLog.t()
              | DAssign.t()
              | DScript.t()
              | %{if: DIf.t(), branches: [[non_neg_integer()]]}
              | %{foreach: DForeach.t(), content: [non_neg_integer()]}
          },
          donedata_acc: %{optional(non_neg_integer()) => DDonedata.t()},
          d_next: non_neg_integer(),
          data_acc: %{
            optional(non_neg_integer()) => %{data: DData.t(), state_index: non_neg_integer()}
          }
        }

  @doc """
  Compiles an already-validated `%Statifier.Document{}` into a flat
  `%Statifier.Machine{}`: every state interned to a document-order index with
  parent pointers and self-inclusive descendant ranges, every `initial`
  resolved to indexes, every transition (including an `<initial>` element's
  own and a `:history` state's default) compiled to
  `Statifier.Machine.Transition`, and every reachable executable-content node
  compiled to `Statifier.Machine.Content` or `Statifier.Machine.Donedata`.

  Returns `{:ok, machine}` on success. A `Document` that reached this stage
  is expected to already be structurally valid - `compile/1` does not
  re-run validator checks - so `{:error, errors}` here signals a compiler
  defect (an id that fails to resolve during the numbering walk) rather than
  a malformed input document; callers should treat it as unexpected, not as
  routine error-event handling.
  """
  @spec compile(document :: Document.t()) :: {:ok, Machine.t()} | {:error, [Error.t()]}
  def compile(%Document{} = document) do
    acc0 = %{
      id_to_index: %{},
      states_acc: %{},
      t_next: 0,
      transitions_acc: %{},
      c_next: 0,
      contents_acc: %{},
      donedata_acc: %{},
      d_next: 0,
      data_acc: %{}
    }

    # The root's own top-level <datamodel> is assigned before the walk, so
    # its <data> occupy d_index 0..n-1 and every state-scoped <data>
    # follows - see moduledoc.
    acc0 = assign_data(document.datamodel_element, 0, acc0)

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
    # build_data_elements/2 never fails and never joins the error merge
    # below - a <data expr> compile failure is captured onto the compiled
    # node itself (Decision 2), not raised here.
    {:ok, data_elements} = build_data_elements(acc.data_acc, acc.d_next)

    # `document.scripts` (Decision 7, Phase 3) is a separate compilation
    # pass, not routed through walk_siblings/4's numbering: a top-level
    # <script> is not in the contents tuple's c_index address space (see
    # Machine's own "why global_scripts is different" moduledoc section),
    # so it never enters assign_content_nodes/2 and needs no dense index
    # of its own to be numbered alongside - build_global_scripts/1 never
    # fails and never joins the error merge below either, for the same
    # deferral reason build_data_elements/2 does not: a compile failure is
    # captured as {:invalid, error} on the list entry itself (Decision 1).
    global_scripts = build_global_scripts(document.scripts)

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
        state_data_map = state_data_map(acc.data_acc)

        states =
          0..root_last
          |> Enum.map(fn index ->
            Map.fetch!(states_acc, index)
            |> with_donedata(donedata_map)
            |> with_data(state_data_map)
          end)
          |> List.to_tuple()

        machine = %Machine{
          states: states,
          id_to_index: acc.id_to_index,
          transitions: transitions,
          contents: contents,
          data_elements: data_elements,
          name: document.name,
          datamodel: document.datamodel,
          binding: document.binding,
          location: document.location,
          global_scripts: global_scripts
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

  # Folds the per-state d_index list onto the compiled state - mirrors
  # with_donedata/2 above.
  @spec with_data(
          mstate :: MState.t(),
          state_data_map :: %{optional(non_neg_integer()) => [non_neg_integer()]}
        ) :: MState.t()
  defp with_data(%MState{index: index} = mstate, state_data_map) do
    case Map.fetch(state_data_map, index) do
      {:ok, d_indexes} -> %{mstate | data: d_indexes}
      :error -> mstate
    end
  end

  # Groups data_acc's d_index-keyed entries back by owning state index, in
  # ascending d_index order (already the document-order sequence
  # assign_data/3 assigned), for with_data/2 to fold onto each compiled
  # state.
  @spec state_data_map(
          data_acc :: %{
            optional(non_neg_integer()) => %{data: DData.t(), state_index: non_neg_integer()}
          }
        ) :: %{optional(non_neg_integer()) => [non_neg_integer()]}
  defp state_data_map(data_acc) do
    data_acc
    |> Enum.group_by(
      fn {_d_index, %{state_index: state_index}} -> state_index end,
      fn {d_index, _entry} -> d_index end
    )
    |> Map.new(fn {state_index, d_indexes} -> {state_index, Enum.sort(d_indexes)} end)
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
    acc = assign_data(dstate.datamodel_element, index, acc)

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

  # Assigns dense, ascending `d_index` values to `datamodel`'s `<data>`
  # children (nil when the container - a state or the root - wrote no
  # `<datamodel>`), in source order, recording each raw
  # `%Statifier.Document.Data{}` and its owning state index for
  # `build_data_elements/2` to compile later. Called at the point the
  # container itself is visited, before the walk descends into its
  # children - assign_own_content_and_transitions/3's rule, applied here to
  # keep every d_index dense and in document order without a second walk.
  @spec assign_data(
          datamodel :: DDatamodel.t() | nil,
          state_index :: non_neg_integer(),
          acc :: acc()
        ) :: acc()
  defp assign_data(nil, _state_index, acc), do: acc

  defp assign_data(%DDatamodel{data: data_list}, state_index, acc) do
    Enum.reduce(data_list, acc, fn %DData{} = data, acc ->
      d_index = acc.d_next
      entry = %{data: data, state_index: state_index}

      %{acc | d_next: d_index + 1, data_acc: Map.put(acc.data_acc, d_index, entry)}
    end)
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
  # `[Statifier.Document.Raise.t() | Statifier.Document.Log.t() |
  # Statifier.Document.Assign.t() | Statifier.Document.If.t()]`, either a
  # block's own content, a transition's own content, or an `<if>` branch's
  # own content), in source order, recording each raw node (or, for an
  # `<if>`, its branch index lists too - see `assign_content_node/2`) for
  # `build_contents/2` to compile later. Returns the assigned `c_index`es in
  # the same order as `nodes`.
  @spec assign_content_nodes(
          nodes :: [
            DRaise.t() | DLog.t() | DAssign.t() | DIf.t() | DForeach.t() | DScript.t()
          ],
          acc :: acc()
        ) ::
          {[non_neg_integer()], acc()}
  defp assign_content_nodes(nodes, acc) do
    {c_indexes, acc} =
      Enum.reduce(nodes, {[], acc}, fn node, {c_indexes, acc} ->
        {c_index, acc} = assign_content_node(node, acc)
        {[c_index | c_indexes], acc}
      end)

    {Enum.reverse(c_indexes), acc}
  end

  # One content node's own `c_index` assignment (Decision 2): a `<raise>`/
  # `<log>`/`<assign>` node has no children of its own, so it is assigned its
  # `c_index` and stored raw, exactly as before this phase. An `<if>` has
  # children - its own branches' content - so its `c_index` is assigned
  # *first* (the `<if>` open tag precedes its children in document order),
  # then each branch's content list is walked in turn through this same
  # function (`assign_content_nodes/2`, indirectly, via `Enum.map_reduce/3`),
  # which is what keeps `c_index` dense and in document order to arbitrary
  # nesting depth - a nested `<if>` inside a branch recurses again the same
  # way.
  @spec assign_content_node(
          node :: DRaise.t() | DLog.t() | DAssign.t() | DIf.t() | DForeach.t() | DScript.t(),
          acc :: acc()
        ) ::
          {non_neg_integer(), acc()}
  defp assign_content_node(%DIf{} = if_node, acc) do
    c_index = acc.c_next
    acc = %{acc | c_next: c_index + 1}

    {branch_indexes, acc} =
      Enum.map_reduce(if_node.branches, acc, fn branch, acc ->
        assign_content_nodes(branch.content, acc)
      end)

    entry = %{if: if_node, branches: branch_indexes}
    acc = %{acc | contents_acc: Map.put(acc.contents_acc, c_index, entry)}

    {c_index, acc}
  end

  # A `<foreach>`'s own `c_index` is assigned first - its open tag precedes
  # its children in document order, the same rule the `%DIf{}` clause above
  # follows - then its flat `content` list is walked once through
  # `assign_content_nodes/2` (Decision 8: one list, not one per branch),
  # which recurses to arbitrary nesting depth for a nested `<if>` or
  # `<foreach>` the same way the `%DIf{}` clause does.
  defp assign_content_node(%DForeach{} = foreach_node, acc) do
    c_index = acc.c_next
    acc = %{acc | c_next: c_index + 1}

    {content_indexes, acc} = assign_content_nodes(foreach_node.content, acc)

    entry = %{foreach: foreach_node, content: content_indexes}
    acc = %{acc | contents_acc: Map.put(acc.contents_acc, c_index, entry)}

    {c_index, acc}
  end

  defp assign_content_node(node, acc) do
    c_index = acc.c_next

    acc = %{
      acc
      | c_next: c_index + 1,
        contents_acc: Map.put(acc.contents_acc, c_index, node)
    }

    {c_index, acc}
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

  @spec build_content_node(
          c_index :: non_neg_integer(),
          node ::
            DRaise.t()
            | DLog.t()
            | DAssign.t()
            | DScript.t()
            | %{if: DIf.t(), branches: [[non_neg_integer()]]}
            | %{foreach: DForeach.t(), content: [non_neg_integer()]}
        ) ::
          {:ok, MContent.t()} | {:error, [Error.t()]} | {:error, Error.t()}
  defp build_content_node(c_index, %{
         foreach: %DForeach{} = foreach_node,
         content: content_indexes
       }) do
    case Expressions.compile(
           foreach_node.array,
           {:content, c_index},
           array_location(foreach_node)
         ) do
      {:ok, array_expr} ->
        {:ok,
         %MForeach{
           c_index: c_index,
           location: foreach_node.location,
           array: array_expr,
           array_location: array_location(foreach_node),
           item: foreach_node.item,
           item_location: item_location(foreach_node),
           index: foreach_node.index,
           index_location: index_location(foreach_node),
           content: content_indexes
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_content_node(c_index, %{if: %DIf{} = if_node, branches: branch_indexes}) do
    results =
      if_node.branches
      |> Enum.zip(branch_indexes)
      |> Enum.map(fn {branch, content_indexes} ->
        build_if_branch(c_index, branch, content_indexes)
      end)

    case collect(results) do
      {:ok, branches} ->
        {:ok, %MIf{c_index: c_index, location: if_node.location, branches: branches}}

      {:error, errors} ->
        {:error, errors}
    end
  end

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

  # No `expr`: the value-source ladder's remaining two rungs (Phase 3,
  # mirroring `build_data_value/2` minus `src` - `<assign>` has no `src`
  # attribute) - non-blank child text folded through
  # `Statifier.Compiler.Expressions.inline_value/1` (Decision 8 of the
  # st-af3.3 plan), a whitespace-only or absent `text` falling to
  # `{:static, nil}`. `inline_value/1` is reused rather than
  # `Expressions.compile/3` because spec 5.4.2's "children ... provide an
  # in-line specification of the legal data value" and 5.9.3 give `<assign>`
  # children the same *value*, not *expression*, semantics 5.3.2 gives
  # `<data>` children - the same reasoning `build_data_value/2`'s own
  # `<data>` text rung already rests on.
  defp build_content_node(c_index, %DAssign{expr: nil} = assign) do
    {:ok,
     %MAssign{
       c_index: c_index,
       location: assign.location,
       node_location: assign.node_location,
       value: assign_text_value(assign),
       location_location: assign_location_location(assign)
     }}
  end

  # `<assign expr>` compiles like every other expression - **except** a
  # compile failure is captured as `{:invalid, error}` on the compiled node
  # rather than returned as `{:error, error}` (Decision 6,
  # `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md`): spec
  # 5.9.4 permits a load-time rejection or a runtime `error.execution`, and
  # `assign_invalid_test.exs` in the corpus needs the latter - the same
  # deferral `build_data_value/2` already gives `<data expr>`. Unlike that
  # deferral, this clause never fails `build_contents/2`'s `collect/1` merge
  # either, so `compile/1` still returns `{:ok, machine}` for a document
  # whose only defect is a malformed `<assign expr>`. `expr` takes
  # precedence over any child text the document also carries -
  # `Statifier.Validator.Checks.Assign` is what rejects a document
  # specifying both (spec 5.4.2), so a document that reaches this compiler
  # never legally has both.
  defp build_content_node(c_index, %DAssign{expr: source} = assign) do
    value =
      case Expressions.compile(source, {:content, c_index}, assign_expr_location(assign)) do
        {:ok, expr} -> expr
        {:error, error} -> {:invalid, error}
      end

    {:ok,
     %MAssign{
       c_index: c_index,
       location: assign.location,
       node_location: assign.node_location,
       value: value,
       location_location: assign_location_location(assign),
       expr_location: assign_expr_location(assign)
     }}
  end

  # `<script>` (ADR-0026, Phase 2): compiled with `compile_program/3`, not
  # `compile/3` - a program is a `Machine.program()`, `expr()`'s sibling,
  # never one of its arms (`Statifier.Machine`'s own `program()` typedoc).
  # A compile failure is captured as `{:invalid, error}` on the compiled
  # node rather than returned as `{:error, error}` (Decision 1 of
  # `docs/plans/260814-st-af3.17-script-statement-bodies.md`) - the same
  # deferral `<assign expr>` and `<data expr>` already take, and for the
  # same reason: an ECMAScript-bodied `<script>` this engine cannot compile
  # should not make an otherwise-fully-supported document unloadable. This
  # clause never fails `build_contents/2`'s `collect/1` merge either.
  defp build_content_node(c_index, %DScript{text: source} = script) do
    program =
      case Expressions.compile_program(source || "", {:content, c_index}, script.location) do
        {:ok, program} -> program
        {:error, error} -> {:invalid, error}
      end

    {:ok,
     %MScript{
       c_index: c_index,
       program: program,
       node_location: script.location
     }}
  end

  # `document.scripts` (Decision 7, Phase 3) compiled to
  # `Machine.global_scripts`, in document order - the separate pass this
  # module's own `compile/1` calls before building `%Machine{}`. Each entry
  # is compiled with `compile_program/3` exactly as `build_content_node/2`'s
  # `%DScript{}` clause above compiles executable-content `<script>`, and a
  # compile failure is captured the same way: `{:invalid, error}` on the
  # list entry rather than failing `compile/1` (Decision 1) - an
  # ECMAScript-bodied top-level `<script>` should not make an otherwise
  # fully-supported document unloadable, any more than one nested in
  # `<onentry>` does. The owner is `{:global_script, index}` - `index` is
  # the script's position in `document.scripts`, not a `c_index`: a
  # top-level script is compiled outside `assign_content_nodes/2`'s walk
  # entirely, so it was never assigned one (`Statifier.Compiler.Expressions
  # .owner_ref/0`'s own typedoc).
  @spec build_global_scripts(scripts :: [DScript.t()]) :: [
          Machine.program() | {:invalid, Error.t()}
        ]
  defp build_global_scripts(scripts) do
    scripts
    |> Enum.with_index()
    |> Enum.map(fn {%DScript{text: source} = script, index} ->
      case Expressions.compile_program(source || "", {:global_script, index}, script.location) do
        {:ok, program} -> program
        {:error, error} -> {:invalid, error}
      end
    end)
  end

  # `attribute_locations[:expr]`'s value span when the author wrote `expr`
  # and it carries a recorded span, the `<log>` node's own `location`
  # otherwise (`Statifier.Compiler.Expressions.compile/3`'s "caller's
  # choice" contract) - mirrors `cond_location/1`.
  @spec expr_location(log :: DLog.t()) :: Location.t()
  defp expr_location(%DLog{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :expr, location)
  end

  # The no-`expr` value: non-blank child text folded through
  # `Expressions.inline_value/1`, `{:static, nil}` for a `nil` or
  # whitespace-only `text` - mirrors `build_data_value/2`'s own text rung.
  # `%DAssign{}.text` is only ever `nil` for a hand-built struct that never
  # passed through lowering; `build_assign/2` always sets it to
  # `Statifier.Parser.DOM.text/1`'s result (possibly `""`) for anything
  # actually parsed.
  @spec assign_text_value(assign :: DAssign.t()) :: Machine.expr()
  defp assign_text_value(%DAssign{text: nil}), do: Expressions.static(nil)

  defp assign_text_value(%DAssign{text: text}) do
    if assign_text_blank?(text) do
      Expressions.static(nil)
    else
      Expressions.inline_value(text)
    end
  end

  @spec assign_text_blank?(text :: String.t()) :: boolean()
  defp assign_text_blank?(text), do: String.trim(text) == ""

  # `assign_expr_location/1` and `assign_location_location/1` mirror
  # `expr_location/1`'s "caller's choice" contract but cannot share its body:
  # `%DAssign{}`'s own element span lives under `node_location`, not
  # `location` - `location` on that struct is the SCXML `location`
  # *attribute* itself (a raw path string), per `Statifier.Document.Assign`'s
  # moduledoc.
  @spec assign_expr_location(assign :: DAssign.t()) :: Location.t()
  defp assign_expr_location(%DAssign{attribute_locations: attribute_locations} = assign) do
    Map.get(attribute_locations, :expr, assign.node_location)
  end

  @spec assign_location_location(assign :: DAssign.t()) :: Location.t()
  defp assign_location_location(%DAssign{attribute_locations: attribute_locations} = assign) do
    Map.get(attribute_locations, :location, assign.node_location)
  end

  # Compiles one `<if>`/`<elseif>`/`<else>` branch's `cond` (Decision 6: same
  # load-time treatment `<transition cond>` already gets via `build_cond/2` -
  # a bad `cond` fails `compile/1`, never deferred the way `<assign expr>` is).
  # `if_c_index` is the *owning* `<if>`'s own `c_index` - `Expressions.compile/3`
  # only needs an owner ref for its error case, and a branch has no `c_index`
  # of its own to give it (Decision 8: `Statifier.Machine.Content.If.Branch`
  # carries no `c_index`, only its compiled `cond`, `cond_location`, and
  # `content` index list). `cond: nil` (the `<else>` branch, spec 4.5.1) never
  # reaches `Expressions.compile/3` at all - there is nothing to compile.
  @spec build_if_branch(
          if_c_index :: non_neg_integer(),
          branch :: DIf.Branch.t(),
          content_indexes :: [non_neg_integer()]
        ) :: {:ok, MIf.Branch.t()} | {:error, Error.t()}
  defp build_if_branch(_if_c_index, %DIf.Branch{cond: nil}, content_indexes) do
    {:ok, %MIf.Branch{cond: nil, cond_location: nil, content: content_indexes}}
  end

  defp build_if_branch(if_c_index, %DIf.Branch{cond: source} = branch, content_indexes) do
    case Expressions.compile(source, {:content, if_c_index}, branch_cond_location(branch)) do
      {:ok, cond_expr} ->
        {:ok,
         %MIf.Branch{
           cond: cond_expr,
           cond_location: branch_cond_location(branch),
           content: content_indexes
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # `attribute_locations[:array]`'s value span when the author wrote
  # `array` and it carries a recorded span, the `<foreach>` node's own
  # `location` otherwise - mirrors `cond_location/1`. `array` is always
  # present (a lowering-time required attribute), so this never returns
  # `nil`, unlike `cond_location/1`.
  @spec array_location(foreach_node :: DForeach.t()) :: Location.t()
  defp array_location(%DForeach{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :array, location)
  end

  # `attribute_locations[:item]`'s value span, mirroring `array_location/1`
  # - carried on the compiled `%MForeach{}` for ADR-0012 constraint 4's
  # benefit (a diagnostic for `{:illegal_item_name, _}` points at the
  # attribute, not the whole element), even though `item` is never a
  # compiled expression itself.
  @spec item_location(foreach_node :: DForeach.t()) :: Location.t()
  defp item_location(%DForeach{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :item, location)
  end

  # `attribute_locations[:index]`'s value span - `nil` when `index` itself
  # was never written, mirroring `cond_location/1`'s "non-nil together"
  # contract.
  @spec index_location(foreach_node :: DForeach.t()) :: Location.t() | nil
  defp index_location(%DForeach{index: nil}), do: nil

  defp index_location(%DForeach{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :index, location)
  end

  # `attribute_locations[:cond]`'s value span when the branch wrote `cond`
  # and it carries a recorded span, the branch's own `location` otherwise -
  # mirrors `cond_location/1` (a transition's own `cond` span rule).
  @spec branch_cond_location(branch :: DIf.Branch.t()) :: Location.t() | nil
  defp branch_cond_location(%DIf.Branch{cond: nil}), do: nil

  defp branch_cond_location(%DIf.Branch{
         attribute_locations: attribute_locations,
         location: location
       }) do
    Map.get(attribute_locations, :cond, location)
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
          {:ok, MDonedata.t()} | {:error, Error.t() | [Error.t()]}
  defp build_donedata(index, %DDonedata{location: location, content: nil, params: params}) do
    case build_donedata_params(params, index) do
      {:ok, mparams} ->
        {:ok, %MDonedata{location: location, expr: nil, expr_location: nil, params: mparams}}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp build_donedata(index, %DDonedata{location: location, content: %DContent{} = content}) do
    case build_content_expr(content, {:donedata, index}) do
      {:ok, expr} ->
        {:ok,
         %MDonedata{
           location: location,
           expr: expr,
           expr_location: content_expr_location(content),
           params: []
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # Compiles a `<donedata>`'s `<param>` children in document order. Mutually
  # exclusive with the `<content>` arm above by validator check
  # (`Statifier.Validator.Checks.Donedata`), so this clause is only ever
  # reached with `content: nil`.
  @spec build_donedata_params(params :: [DParam.t()], index :: non_neg_integer()) ::
          {:ok, [MParam.t()]} | {:error, [Error.t()]}
  defp build_donedata_params(params, index) do
    params
    |> Enum.map(&build_donedata_param(&1, index))
    |> collect()
  end

  # A single `<param>` compiles its `expr` or `location` attribute (exactly
  # one is present - `Statifier.Validator.Checks.Param`) through the same
  # value-expression path either way (Decision 4 -
  # `Statifier.Machine.Param`'s moduledoc). The diagnostic span mirrors
  # `content_expr_location/1`: the written attribute's value span, or the
  # `<param>` node's own location as a fallback that a validated document
  # never actually needs.
  @spec build_donedata_param(param :: DParam.t(), index :: non_neg_integer()) ::
          {:ok, MParam.t()} | {:error, Error.t()}
  defp build_donedata_param(%DParam{expr: source, param_location: nil} = param, index)
       when not is_nil(source) do
    build_param(param, :expr, source, index)
  end

  defp build_donedata_param(%DParam{param_location: source} = param, index)
       when not is_nil(source) do
    build_param(param, :location, source, index)
  end

  @spec build_param(
          param :: DParam.t(),
          kind :: MParam.kind(),
          source :: String.t(),
          index :: non_neg_integer()
        ) :: {:ok, MParam.t()} | {:error, Error.t()}
  defp build_param(%DParam{name: name} = param, kind, source, index) do
    param_expr_location = param_expr_location(param)

    case Expressions.compile(source, {:donedata, index}, param_expr_location) do
      {:ok, expr} ->
        {:ok,
         %MParam{
           name: name,
           kind: kind,
           expr: expr,
           expr_location: param_expr_location,
           location: param.location
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # `attribute_locations[:expr]` when `expr` was written,
  # `attribute_locations[:location]` when `location` was written, the
  # `<param>` node's own `location` as the fallback `content_expr_location/1`
  # also falls back to.
  @spec param_expr_location(param :: DParam.t()) :: Location.t()
  defp param_expr_location(%DParam{
         expr: expr,
         attribute_locations: attribute_locations,
         location: location
       }) do
    key = if is_nil(expr), do: :location, else: :expr
    Map.get(attribute_locations, key, location)
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

  # Compiles every collected `<data>` node into `Statifier.Machine.Data.t()`,
  # dense from `d_index` 0. Unlike build_transitions/3, build_contents/2,
  # and build_donedata_map/1, this pass never fails and never joins their
  # error merge: a <data expr> that fails to compile is captured as
  # `{:invalid, error}` on the compiled node itself (Decision 2,
  # docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md), so
  # `compile/1` can still return `{:ok, machine}` for a document whose only
  # defect is a malformed <data expr>.
  @spec build_data_elements(
          data_acc :: %{
            optional(non_neg_integer()) => %{data: DData.t(), state_index: non_neg_integer()}
          },
          d_count :: non_neg_integer()
        ) :: {:ok, tuple()}
  defp build_data_elements(_data_acc, 0), do: {:ok, {}}

  defp build_data_elements(data_acc, d_count) do
    elements =
      Enum.map(0..(d_count - 1), fn d_index ->
        %{data: data} = Map.fetch!(data_acc, d_index)
        build_data(d_index, data)
      end)

    {:ok, List.to_tuple(elements)}
  end

  @spec build_data(d_index :: non_neg_integer(), data :: DData.t()) :: MData.t()
  defp build_data(d_index, %DData{id: id, location: location} = data) do
    {value, value_location} = build_data_value(d_index, data)

    %MData{
      d_index: d_index,
      id: id,
      value: value,
      location: location,
      value_location: value_location
    }
  end

  # Value selection, per <data>, in spec 5.3.2's own precedence - expr,
  # then src, then non-blank child text, then none - the validator having
  # already rejected any two-of-three combination on a document that
  # reaches this compiler.
  @spec build_data_value(d_index :: non_neg_integer(), data :: DData.t()) ::
          {MData.value(), Location.t()}
  defp build_data_value(d_index, %DData{expr: expr} = data) when is_binary(expr) do
    location = data_expr_location(data)

    case Expressions.compile(expr, {:data, d_index}, location) do
      {:ok, compiled} -> {compiled, location}
      {:error, error} -> {{:invalid, error}, location}
    end
  end

  defp build_data_value(_d_index, %DData{src: src} = data) when is_binary(src) do
    {{:src, src}, data_src_location(data)}
  end

  defp build_data_value(_d_index, %DData{text: text} = data) when is_binary(text) do
    if data_text_blank?(text) do
      {Expressions.static(nil), data.location}
    else
      {Expressions.inline_value(text), data.location}
    end
  end

  defp build_data_value(_d_index, %DData{} = data), do: {Expressions.static(nil), data.location}

  @spec data_text_blank?(text :: String.t()) :: boolean()
  defp data_text_blank?(text), do: String.trim(text) == ""

  # `attribute_locations[:expr]`'s value span when the author wrote `expr`,
  # the `<data>` node's own `location` otherwise (mirrors `cond_location/1`
  # and `expr_location/1`).
  @spec data_expr_location(data :: DData.t()) :: Location.t()
  defp data_expr_location(%DData{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :expr, location)
  end

  # `attribute_locations[:src]`'s value span when the author wrote `src`,
  # the `<data>` node's own `location` otherwise - same shape as
  # `data_expr_location/1`.
  @spec data_src_location(data :: DData.t()) :: Location.t()
  defp data_src_location(%DData{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :src, location)
  end

  # Collects a list of `{:ok, value} | {:error, Error.t()} | {:error, [Error.t()]}`
  # results into `{:ok, [value]} | {:error, [Error.t()]}`, sorted by
  # `location.start_offset` on the error path - the one shape
  # `build_transitions/3`, `build_contents/2`, and `build_donedata_map/1`
  # all need. The error side of each result is normally a single `Error.t()`
  # (one node, one possible defect), but `build_content_node/2`'s `<if>`
  # clause collects every branch's `cond` error rather than short-circuiting
  # at the first (Decision 6), so its own `{:error, _}` carries a *list* -
  # `List.wrap/1` normalizes both shapes to a list before flattening, a
  # no-op for every existing single-error caller.
  @spec collect(results :: [{:ok, term()} | {:error, Error.t()} | {:error, [Error.t()]}]) ::
          {:ok, [term()]} | {:error, [Error.t()]}
  defp collect(results) do
    errors =
      results
      |> Enum.filter(&match?({:error, _error}, &1))
      |> Enum.flat_map(fn {:error, error_or_errors} -> List.wrap(error_or_errors) end)
      |> Enum.sort_by(& &1.location.start_offset)

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, value} -> value end)}
      errors -> {:error, errors}
    end
  end
end
