defmodule Statifier.CompilerTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Exercises every `initial` source (Decision changes required #4): an
  # `initial` attribute pointing at a *non-first* child (`compound_attr` ->
  # `child_b`), an `<initial>` element pointing at a non-first child
  # (`compound_element` -> `child_d`), the first-child default
  # (`default_entry`, `region_a`, `region_b`, `history_holder` - whose first
  # child is a real state, not its own history children), a nameless state
  # (the lone child of `child_b`), a `<parallel>` with a leading `<history>`
  # (`par`), and a compound state with two history children of its own
  # (`history_holder`).
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="compound_attr">
      <state id="compound_attr" initial="child_b">
          <state id="child_a">
              <transition event="go" target="child_b"/>
          </state>
          <state id="child_b">
              <state/>
          </state>
      </state>
      <state id="compound_element">
          <initial>
              <transition target="child_d"/>
          </initial>
          <state id="child_c"/>
          <state id="child_d"/>
      </state>
      <state id="default_entry">
          <state id="def_first"/>
          <state id="def_second"/>
      </state>
      <parallel id="par">
          <history id="par_hist" type="deep">
              <transition target="region_a_1"/>
          </history>
          <state id="region_a">
              <state id="region_a_1"/>
          </state>
          <state id="region_b">
              <state id="region_b_1"/>
          </state>
      </parallel>
      <state id="history_holder">
          <state id="h_child_1"/>
          <state id="h_child_2">
              <state id="h_child_2_a"/>
          </state>
          <history id="shallow_hist" type="shallow">
              <transition target="h_child_1"/>
          </history>
          <history id="deep_hist" type="deep">
              <transition target="h_child_2_a"/>
          </history>
      </state>
      <final id="done"/>
  </scxml>
  """

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root)
  #  1   compound_attr        (children [2,3], last 4)
  #  2     child_a
  #  3     child_b            (children [4], last 4)
  #  4       <nameless>
  #  5   compound_element     (children [6,7], last 7)
  #  6     child_c
  #  7     child_d
  #  8   default_entry        (children [9,10], last 10)
  #  9     def_first
  # 10     def_second
  # 11   par                  (children [12,13,15], last 16)
  # 12     par_hist
  # 13     region_a           (children [14], last 14)
  # 14       region_a_1
  # 15     region_b           (children [16], last 16)
  # 16       region_b_1
  # 17   history_holder       (children [18,19,21,22], last 22)
  # 18     h_child_1
  # 19     h_child_2          (children [20], last 20)
  # 20       h_child_2_a
  # 21     shallow_hist
  # 22     deep_hist
  # 23   done
  @indexes %{
    compound_attr: 1,
    child_a: 2,
    child_b: 3,
    nameless: 4,
    compound_element: 5,
    child_c: 6,
    child_d: 7,
    default_entry: 8,
    def_first: 9,
    def_second: 10,
    par: 11,
    par_hist: 12,
    region_a: 13,
    region_a_1: 14,
    region_b: 15,
    region_b_1: 16,
    history_holder: 17,
    h_child_1: 18,
    h_child_2: 19,
    h_child_2_a: 20,
    shallow_hist: 21,
    deep_hist: 22,
    done: 23
  }

  describe "compile/1 - numbering" do
    # sabotage: `Statifier.Compiler.walk_siblings/5` recurses into a state's
    # own children with `index + 2` instead of `index + 1` -> the tuple
    # gains gaps, and this assertion (every index 0..last present, once)
    # goes red.
    test "assigns a contiguous, gapless index to every state, root first" do
      machine = compile!(@document)

      indexes = machine.states |> Tuple.to_list() |> Enum.map(& &1.index)

      assert indexes == Enum.to_list(0..23)
    end

    # sabotage: the final tuple assembly in `Compiler.compile/1` looks up
    # `Map.fetch!(states_acc, index + 1)` instead of `Map.fetch!(states_acc,
    # index)` -> every state's `.index` field disagrees with its own tuple
    # position, reddening this assertion.
    test "tuple position i always holds the state whose own index is i" do
      machine = compile!(@document)

      machine.states
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.each(fn {state, position} -> assert state.index == position end)
    end

    # sabotage: `last = next_after_subtree - 1` becomes `last =
    # next_after_subtree` -> every state's range now claims one index past
    # its actual subtree, and this self-inclusive/contiguous check goes red.
    test "every descendant range is contiguous and self-inclusive" do
      machine = compile!(@document)

      Enum.each(Tuple.to_list(machine.states), fn state ->
        assert state.last >= state.index

        descendant_indexes =
          machine.states
          |> Tuple.to_list()
          |> Enum.filter(&(&1.index >= state.index and &1.index <= state.last))
          |> Enum.map(& &1.index)

        assert descendant_indexes == Enum.to_list(state.index..state.last)
      end)

      root = elem(machine.states, 0)
      assert root.last == tuple_size(machine.states) - 1
    end

    # sabotage: the recursive call that numbers a state's own children
    # passes `parent_index` (the grandparent) instead of `index` (the state
    # itself) as the new parent -> every grandchild reports its grandparent
    # as its parent, reddening this two-way agreement check.
    test "parent and children agree in both directions" do
      machine = compile!(@document)

      Enum.each(Tuple.to_list(machine.states), fn state ->
        Enum.each(state.children, fn child_index ->
          child = elem(machine.states, child_index)
          assert child.parent == state.index
        end)
      end)
    end

    # sabotage: `mstate.children` is stored as `Enum.reverse(children)`
    # instead of `children` -> `compound_attr`'s children read
    # `[child_b, child_a]`, reddening this order assertion.
    test "children are stored in source order" do
      machine = compile!(@document)

      assert state_of(machine, :compound_attr).children == [
               idx(machine, :child_a),
               idx(machine, :child_b)
             ]

      assert state_of(machine, :par).children == [
               idx(machine, :par_hist),
               idx(machine, :region_a),
               idx(machine, :region_b)
             ]
    end

    # sabotage: `maybe_put_id/3`'s `nil` clause is deleted, so a nameless
    # state's (non-existent) id is inserted into `id_to_index` as a literal
    # `nil` key -> `refute Map.has_key?(machine.id_to_index, nil)` reddens.
    test "a nameless state is absent from id_to_index but present in states" do
      machine = compile!(@document)

      nameless = elem(machine.states, @indexes.nameless)
      assert nameless.id == nil
      refute Map.has_key?(machine.id_to_index, nil)
      assert map_size(machine.id_to_index) == map_size(@indexes) - 1
    end

    # sabotage: `root = %MState{... parent: 0 ...}` (a self-referential
    # parent) instead of `parent: nil` -> this assertion on the root's shape
    # reddens.
    test "the scxml root is index 0, kind :scxml, parent nil, id nil" do
      machine = compile!(@document)
      root = elem(machine.states, 0)

      assert %Machine.State{index: 0, kind: :scxml, parent: nil, id: nil} = root
      assert root.last == tuple_size(machine.states) - 1
    end
  end

  describe "compile/1 - id_to_index round-trips through Machine.index/2 and Machine.id/2" do
    # sabotage: `maybe_put_id/3`'s last clause stores `Map.put(id_to_index,
    # index, id)` (arguments swapped) instead of `Map.put(id_to_index, id,
    # index)` -> `Machine.index/2` can no longer find any id, reddening
    # every round-trip below.
    test "every named state's id resolves back to its own index" do
      machine = compile!(@document)

      @indexes
      |> Map.delete(:nameless)
      |> Enum.each(fn {name, index} ->
        assert Machine.index(machine, Atom.to_string(name)) == {:ok, index}
        assert Machine.id(machine, index) == Atom.to_string(name)
      end)
    end
  end

  describe "compile/1 - history_children" do
    # sabotage: `history_children_of/2` filters on `kind == :state` instead
    # of `kind == :history` -> `par`'s history_children comes back `[]`
    # instead of `[par_hist]`, reddening this assertion.
    test "a compound/parallel state's history_children are its own direct history children" do
      machine = compile!(@document)

      assert state_of(machine, :par).history_children == [idx(machine, :par_hist)]

      assert state_of(machine, :history_holder).history_children == [
               idx(machine, :shallow_hist),
               idx(machine, :deep_hist)
             ]

      assert state_of(machine, :compound_attr).history_children == []
    end
  end

  describe "compile/1 - initial resolution" do
    # sabotage: the `resolve_initial/3` clause matching a written `initial`
    # attribute is deleted -> `compound_attr` falls through to the
    # first-child default (`child_a`, index 2) instead of the attribute's
    # `child_b` (index 3), reddening this assertion. The document
    # deliberately points `initial="child_b"` at a *non-first* child so this
    # sabotage cannot pass by coincidence.
    test "an initial attribute resolves to the named child, even when it is not first" do
      machine = compile!(@document)

      assert state_of(machine, :compound_attr).initial == [idx(machine, :child_b)]
    end

    # sabotage: `resolve_initial/3`'s `<initial>` element clause reads
    # `hd(transition.target)` mapped through a stale `id_to_index` snapshot
    # by using `dstate.initial` (the attribute, always `[]` here) instead of
    # `transition.target` -> `compound_element.initial` comes back `[]`
    # instead of `[child_d]`, reddening this assertion. `target="child_d"`
    # is deliberately not the first child either.
    test "an <initial> element resolves to its transition's target, even when not first" do
      machine = compile!(@document)

      assert state_of(machine, :compound_element).initial == [idx(machine, :child_d)]
    end

    # sabotage: the first-child-default clause returns `[]` instead of
    # `[first]` -> every assertion below reddens.
    test "no initial form defaults to the first child in document order" do
      machine = compile!(@document)

      assert state_of(machine, :default_entry).initial == [idx(machine, :def_first)]
      assert state_of(machine, :region_a).initial == [idx(machine, :region_a_1)]

      # history_holder's first child is a real state (h_child_1), never one
      # of its own two history children - proves the default walks document
      # order rather than skipping history kinds by search.
      assert state_of(machine, :history_holder).initial == [idx(machine, :h_child_1)]
    end

    # sabotage: the `:parallel`/`:final`/`:history`/atomic-state clause
    # (`resolve_initial(%DState{}, _children, _id_to_index), do: []`) is
    # replaced with `do: children` -> `par.initial` comes back its own
    # children list instead of `[]`, reddening this assertion.
    test "parallel, final, history, and atomic states resolve initial to []" do
      machine = compile!(@document)

      assert state_of(machine, :par).initial == []
      assert state_of(machine, :done).initial == []
      assert state_of(machine, :par_hist).initial == []
      assert state_of(machine, :child_a).initial == []
    end

    # sabotage: `resolve_root_initial/3`'s written-attribute clause is
    # deleted -> the root falls through to the first-child default
    # (`compound_attr` again, coincidentally the same value), so the
    # document below points the root's `initial` at `history_holder`
    # instead, which is not the first top-level child.
    test "the root's initial attribute resolves the same way a state's does" do
      xml = String.replace(@document, ~s(initial="compound_attr"), ~s(initial="history_holder"))
      machine = compile!(xml)

      assert Machine.initial(machine) == [idx(machine, :history_holder)]
    end
  end

  defp state_of(machine, name) do
    {:ok, index} = Machine.index(machine, Atom.to_string(name))
    elem(machine.states, index)
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, Atom.to_string(name))
    index
  end
end
