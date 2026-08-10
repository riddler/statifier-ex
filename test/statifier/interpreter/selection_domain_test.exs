defmodule Statifier.Interpreter.SelectionDomainTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Interpreter.Selection
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root, children [1,4,10])
  #  1   a                (children [2,3], last 3)
  #  2     a1
  #  3     a2
  #  4   b                (children [5,8,9], last 9)
  #  5     b1              (children [6,7], last 7)
  #  6       b1a
  #  7       b1b
  #  8     hs              (history, shallow)
  #  9     hd              (history, deep)
  # 10   p                (parallel, children [11,14], last 16)
  # 11     p1              (children [12,13], last 13)
  # 12       p1a
  # 13       p1b
  # 14     p2              (children [15,16], last 16)
  # 15       p2a
  # 16       p2b
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <state id="a1">
              <transition event="a1-internal" target="a2" type="internal"/>
          </state>
          <state id="a2"/>
          <transition event="a-internal" target="a1" type="internal"/>
          <transition event="a-external" target="a1" type="external"/>
          <transition event="a-outside" target="p1a" type="internal"/>
          <transition event="a-self" target="a" type="external"/>
          <transition event="a-targetless"/>
      </state>
      <state id="b">
          <state id="b1">
              <state id="b1a"/>
              <state id="b1b"/>
          </state>
          <history id="hs" type="shallow">
              <transition target="b1a"/>
          </history>
          <history id="hd" type="deep">
              <transition target="b1a"/>
          </history>
          <transition event="b-to-hs" target="hs" type="external"/>
          <transition event="b-multi" target="b1a b1b" type="external"/>
      </state>
      <parallel id="p">
          <state id="p1">
              <state id="p1a">
                  <transition event="p1-move" target="p1b" type="internal"/>
                  <transition event="p1-cross" target="p2a" type="external"/>
              </state>
              <state id="p1b"/>
          </state>
          <state id="p2">
              <state id="p2a">
                  <transition event="p2-move" target="p2b" type="internal"/>
              </state>
              <state id="p2b"/>
          </state>
      </parallel>
  </scxml>
  """

  @indexes %{
    a: 1,
    a1: 2,
    a2: 3,
    b: 4,
    b1: 5,
    b1a: 6,
    b1b: 7,
    hs: 8,
    hd: 9,
    p: 10,
    p1: 11,
    p1a: 12,
    p1b: 13,
    p2: 14,
    p2a: 15,
    p2b: 16
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration \\ [], history_values \\ %{}) do
    %{
      MachineState.new(machine)
      | configuration: MapSet.new(configuration),
        history_values: history_values
    }
  end

  # Finds the transition among `machine`'s own transitions whose single event
  # descriptor is `event_name` - the fixture gives every transition under
  # test a distinct `event` attribute purely as a lookup key. This file does
  # not test event matching (`selection_test.exs` does); this is only how the
  # test picks the `Transition.t()` it wants to hand to a domain/exit-set
  # function.
  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  describe "find_lcca/2" do
    # sabotage: `Selection.find_lcca/2`'s `defdelegate` target is changed from
    # `:lcca` to `:initial` -> this reddens because the delegate no longer
    # returns an LCCA at all.
    test "delegates to Machine.lcca/2" do
      m = machine()
      indexes = [idx(:a1), idx(:a2)]
      assert Selection.find_lcca(m, indexes) == Machine.lcca(m, indexes)
    end
  end

  describe "get_effective_target_states/2" do
    # sabotage: `effective_target_states/2` returns `[target, target]`
    # (duplicates the plain target) instead of `[target]` -> this reddens.
    test "a plain (non-history) target passes through unchanged" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a-internal")

      assert Selection.get_effective_target_states(ms, transition) == [idx(:a1)]
    end

    # sabotage: `history_effective_target_states/3` reads
    # `Machine.at(machine, history_index).history_default` unconditionally,
    # ignoring a recorded `history_values` entry entirely -> this reddens
    # because the recorded value (`b1b`) is dropped in favor of the default
    # (`b1a`).
    test "a history target with a recorded history_values entry yields the recorded set" do
      m = machine()
      ms = machine_state(m, [], %{idx(:hs) => MapSet.new([idx(:b1b)])})
      transition = transition_named(m, "b-to-hs")

      assert Selection.get_effective_target_states(ms, transition) == [idx(:b1b)]
    end

    # sabotage: `history_effective_target_states/3`'s `Map.fetch/2` branches
    # are swapped (`{:ok, _}` recurses through the default, `:error` returns
    # the recorded value) -> this reddens because an unrecorded history no
    # longer falls through to its default transition's targets.
    test "the same history target with no recorded entry yields its default transition's targets" do
      m = machine()
      ms = machine_state(m, [], %{})
      transition = transition_named(m, "b-to-hs")

      assert Selection.get_effective_target_states(ms, transition) == [idx(:b1a)]
    end

    # sabotage: `get_effective_target_states/2` calls
    # `Enum.map(transition.targets, ...)` wrapped in `List.first/1` instead of
    # `Enum.flat_map/2` -> only the first target survives, reddening this
    # assertion.
    test "a multi-target transition yields all of them, in order" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "b-multi")

      assert Selection.get_effective_target_states(ms, transition) == [idx(:b1a), idx(:b1b)]
    end
  end

  describe "get_transition_domain/2" do
    # sabotage: `get_transition_domain/2`'s `[] -> nil` clause is deleted, so
    # a targetless transition falls into `transition_domain/3` and crashes on
    # `find_lcca(machine, [source])` returning a value instead of `nil` ->
    # this reddens.
    test "a targetless transition has no domain" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a-targetless")

      assert Selection.get_transition_domain(ms, transition) == nil
    end

    # sabotage: `transition_domain/3` calls `find_lcca/2` unconditionally
    # instead of returning `source` when the `if` condition holds -> this
    # reddens because the domain comes back as the root (`0`) instead of
    # `idx(:a)`.
    test "internal + compound source + all effective targets descendants -> the source" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a-internal")

      assert Selection.get_transition_domain(ms, transition) == idx(:a)
    end

    # sabotage: `transition_domain/3`'s guard drops the `type == :internal`
    # check entirely (always takes the `source` branch when compound and
    # descendants hold) -> this reddens because the external transition with
    # the identical source/target now also returns `idx(:a)` instead of the
    # LCCA.
    test "the same source and target with type: :external -> the LCCA instead" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a-external")

      assert Selection.get_transition_domain(ms, transition) == 0
    end

    # sabotage: `transition_domain/3`'s two branches are swapped (`source`
    # and `find_lcca(...)` traded places) -> this reddens because the
    # `if` condition is false here (atomic source), so the swapped code
    # wrongly returns `source` (`idx(:a1)`) instead of the LCCA `idx(:a)`.
    test "internal but source atomic -> LCCA" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a1-internal")

      assert Selection.get_transition_domain(ms, transition) == idx(:a)
    end

    # sabotage: `transition_domain/3` drops the `Enum.all?(effective_targets,
    # &Machine.descendant?(machine, &1, source))` check from the `if`
    # condition entirely -> this reddens because `p1a` (outside `a`'s
    # subtree) is no longer rejected, so the branch wrongly returns
    # `idx(:a)` instead of falling through to the LCCA.
    test "internal but a target outside the source -> LCCA" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "a-outside")

      assert Selection.get_transition_domain(ms, transition) == 0
    end

    # sabotage: `Machine.lcca/2`'s `compound?/2` filter is widened to admit
    # `:parallel` (mirrors `machine_test.exs`'s own LCCA sabotage) -> this
    # reddens because `p` itself, not the root, would be wrongly returned.
    test "a cross-region transition in a parallel -> the ancestor above the parallel" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "p1-cross")

      assert Selection.get_transition_domain(ms, transition) == 0
    end
  end

  describe "compute_exit_set/2" do
    # sabotage: `compute_exit_set/2`'s `Enum.reduce/3` is seeded with every
    # transition's own `source` (`MapSet.new(Enum.map(transitions, &
    # &1.source))`) instead of the empty set -> this reddens because the
    # targetless transition's own source ends up in the "exit set" it should
    # contribute nothing to.
    test "a targetless transition contributes the empty set" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:a1)])
      transition = transition_named(m, "a-targetless")

      assert Selection.compute_exit_set(ms, [transition]) == MapSet.new()
    end

    # sabotage: `descendants_in_configuration/2` swaps `Machine.descendant?/3`'s
    # last two arguments (`Machine.descendant?(machine, domain, &1)` instead
    # of `Machine.descendant?(machine, &1, domain)`) -> this reddens because
    # the exit set comes back empty instead of `{a, a1}`.
    test "a self-transition on a compound state exits the state and its active descendants" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:a1)])
      transition = transition_named(m, "a-self")

      assert Selection.compute_exit_set(ms, [transition]) == MapSet.new([idx(:a), idx(:a1)])
    end

    # sabotage: `descendants_in_configuration/2` uses `Machine.ancestor?/3`
    # instead of `Machine.descendant?/3` -> this reddens because no
    # configuration member reads as "an ancestor of the domain" and the
    # exit set comes back empty instead of `{a1}`.
    test "an internal transition exits only descendants, never its source" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:a1)])
      transition = transition_named(m, "a-internal")

      assert Selection.compute_exit_set(ms, [transition]) == MapSet.new([idx(:a1)])
    end

    # sabotage: `compute_exit_set/2`'s `Enum.reduce/3` accumulator seed
    # changes from `MapSet.new()` to a set already containing every
    # configuration member (`MapSet.new(machine_state.configuration)`) -> this
    # reddens because the two region-internal exit sets would then overlap
    # (both come back equal to the full seeded set) instead of staying
    # disjoint.
    test "two transitions in different parallel regions have disjoint exit sets" do
      m = machine()
      ms = machine_state(m, [idx(:p), idx(:p1), idx(:p1a), idx(:p2), idx(:p2a)])
      t1 = transition_named(m, "p1-move")
      t2 = transition_named(m, "p2-move")

      exit_set_1 = Selection.compute_exit_set(ms, [t1])
      exit_set_2 = Selection.compute_exit_set(ms, [t2])

      assert exit_set_1 == MapSet.new([idx(:p1a)])
      assert exit_set_2 == MapSet.new([idx(:p2a)])
      assert MapSet.disjoint?(exit_set_1, exit_set_2)
    end

    # sabotage: `descendants_in_configuration/2` filters over every state's
    # index (`machine.states`) instead of `machine_state.configuration` ->
    # this reddens because `a1` and `a2`, neither in this test's
    # configuration, wrongly appear in the exit set.
    test "a state not in the configuration is never in the exit set" do
      m = machine()
      ms = machine_state(m, [idx(:a)])
      transition = transition_named(m, "a-internal")

      assert Selection.compute_exit_set(ms, [transition]) == MapSet.new()
    end
  end
end
