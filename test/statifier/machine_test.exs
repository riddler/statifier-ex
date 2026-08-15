defmodule Statifier.MachineTest do
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

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root, children [1,5,10,11])
  #  1   a                (children [2,3,4], last 4)
  #  2     a1
  #  3     a2
  #  4     h               (history)
  #  5   p                (parallel, children [6,8], last 9)
  #  6     p1              (children [7], last 7)
  #  7       p1a
  #  8     p2              (children [9], last 9)
  #  9       p2a
  # 10   <nameless>
  # 11   f                (final)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <state id="a1">
              <transition event="go" target="a2"/>
          </state>
          <state id="a2"/>
          <history id="h" type="shallow">
              <transition target="a1"/>
          </history>
      </state>
      <parallel id="p">
          <state id="p1">
              <state id="p1a"/>
          </state>
          <state id="p2">
              <state id="p2a"/>
          </state>
      </parallel>
      <state/>
      <final id="f"/>
  </scxml>
  """

  @indexes %{
    a: 1,
    a1: 2,
    a2: 3,
    h: 4,
    p: 5,
    p1: 6,
    p1a: 7,
    p2: 8,
    p2a: 9,
    f: 11
  }
  @nameless_index 10

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  describe "descendant?/3" do
    # sabotage: `Machine.descendant?/3` compares with `ancestor <= descendant`
    # instead of `ancestor < descendant` -> a state becomes its own
    # descendant, reddening this refutation. This is the Appendix D
    # `isDescendant` contract ("a child, or a child of a child, ..."), which
    # `compute_exit_set` depends on to leave the transition domain unexited.
    test "a state is not its own descendant (proper, per isDescendant)" do
      m = machine()
      refute Machine.descendant?(m, idx(:a1), idx(:a1))
    end

    # sabotage: `Machine.descendant?/3`'s lower-bound comparison
    # `ancestor < descendant` becomes `descendant < ancestor` (the
    # ancestor/descendant roles are swapped in the comparison) -> a genuine
    # child no longer satisfies the range test, reddening this assertion.
    test "a direct child is a descendant of its parent" do
      m = machine()
      assert Machine.descendant?(m, idx(:a1), idx(:a))
    end

    # sabotage: the `and` in `Machine.descendant?/3` becomes `or` -> a
    # sibling's index alone satisfies one side of the range test, making
    # every sibling wrongly "descendant", reddening this refutation.
    test "a sibling is not a descendant" do
      m = machine()
      refute Machine.descendant?(m, idx(:a2), idx(:a1))
    end

    # sabotage: `Machine.descendant?/3`'s upper-bound comparison
    # `descendant <= last` is loosened to `descendant <= last + 2` -> `p1`'s
    # range now overruns two indexes past its actual subtree, wrongly
    # admitting `p2a` as a descendant of `p1`, reddening this refutation.
    test "a state in one parallel region is not a descendant of a sibling region" do
      m = machine()
      refute Machine.descendant?(m, idx(:p1a), idx(:p2))
      refute Machine.descendant?(m, idx(:p2a), idx(:p1))
    end
  end

  describe "ancestor?/3" do
    # sabotage: `Machine.ancestor?/3` calls `descendant?(machine, ancestor,
    # descendant)` instead of `descendant?(machine, descendant, ancestor)`
    # (arguments not swapped) -> this reddens because a parent is no longer
    # reported as an ancestor of its child.
    test "is the mirror of descendant?/3" do
      m = machine()
      assert Machine.ancestor?(m, idx(:a), idx(:a1))
      refute Machine.ancestor?(m, idx(:a1), idx(:a))
    end
  end

  describe "atomic?/2 and compound?/2" do
    # sabotage: `Machine.atomic?/2` checks `children != []` instead of
    # `children == []` -> every assertion below reddens.
    test "atomic? is true exactly for states with no children" do
      m = machine()
      assert Machine.atomic?(m, idx(:a1))
      refute Machine.atomic?(m, idx(:a))
    end

    # sabotage: `Machine.compound?/2` widens its kind check from `kind in
    # [:state, :scxml]` to `kind in [:state, :scxml, :parallel]` -> `p`
    # (a `:parallel` with children) is wrongly reported compound, reddening
    # this refutation.
    test "compound? excludes :parallel even though it has children" do
      m = machine()
      assert Machine.compound?(m, idx(:a))
      refute Machine.compound?(m, idx(:p))
    end

    # sabotage: `Machine.atomic?/2` is changed to derive atomicity from
    # `kind != :final` instead of `children == []` -> a `:final` (no
    # children, so it should read atomic) instead reads non-atomic,
    # reddening this assertion. This is the case where kind and atomicity
    # are independent facts.
    test "a :final is atomic and not compound" do
      m = machine()
      assert Machine.atomic?(m, idx(:f))
      refute Machine.compound?(m, idx(:f))
    end
  end

  describe "parallel?/2, final?/2, history?/2" do
    # sabotage: `Machine.parallel?/2` compares `.kind == :state` instead of
    # `.kind == :parallel` -> `p` no longer reads parallel, reddening this
    # assertion.
    test "parallel? is true only for :parallel" do
      m = machine()
      assert Machine.parallel?(m, idx(:p))
      refute Machine.parallel?(m, idx(:a))
    end

    # sabotage: `Machine.final?/2` compares `.kind == :state` instead of
    # `.kind == :final` -> `f` no longer reads final, reddening this
    # assertion.
    test "final? is true only for :final" do
      m = machine()
      assert Machine.final?(m, idx(:f))
      refute Machine.final?(m, idx(:a))
    end

    # sabotage: `Machine.history?/2` compares `.kind == :state` instead of
    # `.kind == :history` -> `h` no longer reads history, reddening this
    # assertion.
    test "history? is true only for :history" do
      m = machine()
      assert Machine.history?(m, idx(:h))
      refute Machine.history?(m, idx(:a))
    end
  end

  describe "children/2" do
    # sabotage: `Machine.children/2` reads `.initial` instead of `.children`
    # -> this comes back `[a1's default]` instead of the full children list,
    # reddening this assertion.
    test "returns every direct child in source order, history included" do
      m = machine()
      assert Machine.children(m, idx(:a)) == [idx(:a1), idx(:a2), idx(:h)]
      assert Machine.children(m, idx(:a1)) == []
    end
  end

  describe "child_states/2" do
    # sabotage: `Machine.child_states/2` returns `children` unfiltered
    # (drops the `-- history_children` subtraction) -> `h` comes back in the
    # result, reddening this refutation. This is the `getChildStates`
    # (Appendix D) contract - "a list containing all <state>, <final>, and
    # <parallel> children of state1" - `:history` pseudo-states excluded by
    # definition.
    test "excludes :history children that children/2 includes" do
      m = machine()
      assert Machine.child_states(m, idx(:a)) == [idx(:a1), idx(:a2)]
      assert Machine.children(m, idx(:a)) == [idx(:a1), idx(:a2), idx(:h)]
    end
  end

  describe "proper_ancestors/2" do
    # sabotage: `Machine.proper_ancestors/2` returns `[index | proper_ancestors(machine, parent)]`
    # (including the state itself) instead of `[parent | ...]` -> the first
    # element is no longer the immediate parent, reddening this assertion.
    test "walks nearest-first up to and including the root" do
      m = machine()
      assert Machine.proper_ancestors(m, idx(:p1a)) == [idx(:p1), idx(:p), 0]
    end

    # sabotage: the base case `nil -> []` becomes `nil -> [0]` -> the root's
    # own proper_ancestors comes back `[0]` instead of `[]`, reddening this
    # refutation.
    test "the root has no proper ancestors" do
      m = machine()
      assert Machine.proper_ancestors(m, 0) == []
    end
  end

  describe "lcca/2" do
    # sabotage: `Machine.lcca/2`'s `Enum.find` (nearest qualifying ancestor
    # wins) is replaced with `Enum.filter |> List.last()` (farthest
    # qualifying ancestor wins) -> the `:scxml` root, which is always a
    # qualifying ancestor of everything, is returned instead of `a`,
    # reddening this assertion.
    test "two siblings under a compound state" do
      m = machine()
      assert Machine.lcca(m, [idx(:a1), idx(:a2)]) == idx(:a)
    end

    # sabotage: `Machine.descendant?/3`'s lower bound is loosened back to
    # `ancestor <= descendant` -> `a` becomes its own descendant, so `a`
    # qualifies as the LCCA of a list containing `a` itself and this
    # assertion reddens with `idx(:a)`. This is the shape a transition
    # targeting its own ancestor produces, and `a` cannot be its own
    # transition domain - Appendix D's `findLCCA` rejects it via the
    # proper-descendant test and keeps walking to the root.
    test "a state and its own ancestor - the ancestor cannot be the LCCA" do
      m = machine()
      assert Machine.lcca(m, [idx(:a1), idx(:a)]) == 0
    end

    # sabotage: `Machine.compound?/2` is widened to admit `:parallel`
    # (same mutation as the compound?/2 test above) -> `p` itself, not the
    # root, is wrongly returned as the LCCA of two states in different
    # parallel regions, reddening this assertion. This is the real Appendix
    # D behavior, not an approximation: `isCompoundStateOrScxmlElement`
    # excludes parallel states from LCCA candidacy, so the search skips `p`
    # and keeps walking to the `:scxml` root.
    test "states in different parallel regions - lcca skips the parallel itself" do
      m = machine()
      assert Machine.lcca(m, [idx(:p1a), idx(:p2a)]) == 0
    end
  end

  describe "index/2 and id/2" do
    # sabotage: `Machine.id/2` reads `at(machine, index).kind` instead of
    # `at(machine, index).id` -> every id-side half of the round-trip comes
    # back a kind atom (e.g. `:parallel`) instead of the written id string,
    # reddening this assertion.
    test "round-trips every named state" do
      m = machine()

      Enum.each(@indexes, fn {name, index} ->
        assert Machine.index(m, Atom.to_string(name)) == {:ok, index}
        assert Machine.id(m, index) == Atom.to_string(name)
      end)
    end

    # sabotage: `Machine.index/2` is changed to `{:ok, Map.get(id_to_index,
    # id, 0)}` (defaults to index 0 instead of failing) -> an unknown id
    # wrongly resolves to `{:ok, 0}`, reddening this assertion.
    test "an unknown id resolves to :error" do
      m = machine()
      assert Machine.index(m, "does-not-exist") == :error
    end

    # sabotage: `Machine.id/2` reads `.index` instead of `.id` -> a nameless
    # state's id comes back its own numeric index instead of `nil`,
    # reddening this assertion.
    test "a nameless state's id is nil" do
      m = machine()
      assert Machine.id(m, @nameless_index) == nil
    end
  end

  describe "document_order/2 and exit_order/2" do
    # sabotage: `Machine.document_order/2` sorts `:desc` instead of
    # ascending -> this assertion (ascending order) reddens.
    test "document_order sorts ascending" do
      m = machine()

      assert Machine.document_order(m, [idx(:p2a), idx(:a1), idx(:h)]) == [
               idx(:a1),
               idx(:h),
               idx(:p2a)
             ]
    end

    # sabotage: `Machine.exit_order/2` sorts ascending (drops the `:desc`
    # argument to `Enum.sort/2`) -> exit_order stops being the reverse of
    # document_order, reddening this assertion.
    test "exit_order is the exact reverse of document_order" do
      m = machine()
      indexes = [idx(:p2a), idx(:a1), idx(:h), idx(:p1)]

      assert Machine.exit_order(m, indexes) == Enum.reverse(Machine.document_order(m, indexes))
    end
  end

  describe "warnings" do
    # sabotage: `Statifier.Machine`'s `defstruct` default for `warnings`
    # changes from `[]` to `nil` -> this assertion reddens because a machine
    # compiled from a warning-free document carries `nil` instead of `[]`
    test "defaults to [] on a machine built from a document with no warnings" do
      m = machine()
      assert m.warnings == []
    end
  end

  describe "initial/1" do
    # sabotage: `Machine.initial/1` reads `at(machine, 1)` instead of
    # `at(machine, 0)` -> reddens whenever the root's resolved initial
    # differs from state 1's own `initial` field (state 1, `a`, defaults to
    # its first child `a1` since it carries no `initial` attribute or
    # element, which does differ from the root's `[a]`).
    test "reads the root's resolved initial (no top-level field)" do
      m = machine()
      assert Machine.initial(m) == [idx(:a)]
    end
  end
end
