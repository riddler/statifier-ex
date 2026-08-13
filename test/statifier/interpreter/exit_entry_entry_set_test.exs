defmodule Statifier.Interpreter.ExitEntryEntrySetTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Interpreter.ExitEntry
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

  # Hand-drawn from `@document`, depth-first, document order. `<initial>`
  # elements and `<transition>` elements contribute no state index of their
  # own.
  #
  #  0 scxml (root)
  #  1   region
  #  2     a                  (compound; initial="a1" - explicit attribute)
  #  3       a1
  #  4       a2               (compound; no initial attr -> first child a2x)
  #  5         a2x
  #  6       hs                (history, shallow, default -> a1)
  #  7     b                  (compound; <initial> element -> b2)
  #  8       b1
  #  9       b2
  # 10     c                  (compound; no initial anywhere -> first child c1)
  # 11       c1
  # 12       c2
  # 13     p                  (parallel)
  # 14       p1               (compound; no initial -> p1a)
  # 15         p1a
  # 16         p1b
  # 17       p2               (compound; no initial -> p2a)
  # 18         p2a
  # 19         p2b
  # 20       hd                (history, deep, default -> p1a)
  # 21     leaf
  # 22     domain_holder      (compound; dom-internal/dom-external -> domain_child)
  # 23       domain_child
  # 24     trigger            (go-a1/go-a/go-p/go-p1a/go-none)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="region">
      <state id="region">
          <state id="a" initial="a1">
              <state id="a1"/>
              <state id="a2">
                  <state id="a2x"/>
              </state>
              <history id="hs" type="shallow">
                  <transition target="a1"/>
              </history>
          </state>
          <state id="b">
              <initial>
                  <transition target="b2"/>
              </initial>
              <state id="b1"/>
              <state id="b2"/>
          </state>
          <state id="c">
              <state id="c1"/>
              <state id="c2"/>
          </state>
          <parallel id="p">
              <state id="p1">
                  <state id="p1a"/>
                  <state id="p1b"/>
              </state>
              <state id="p2">
                  <state id="p2a"/>
                  <state id="p2b"/>
              </state>
              <history id="hd" type="deep">
                  <transition target="p1a"/>
              </history>
          </parallel>
          <state id="leaf"/>
          <state id="domain_holder">
              <transition event="dom-internal" target="domain_child" type="internal"/>
              <transition event="dom-external" target="domain_child" type="external"/>
              <state id="domain_child"/>
          </state>
          <state id="trigger">
              <transition event="go-a1" target="a1"/>
              <transition event="go-a" target="a"/>
              <transition event="go-p" target="p"/>
              <transition event="go-p1a" target="p1a" type="external"/>
              <transition event="go-none"/>
          </state>
      </state>
  </scxml>
  """

  @indexes %{
    region: 1,
    a: 2,
    a1: 3,
    a2: 4,
    a2x: 5,
    hs: 6,
    b: 7,
    b1: 8,
    b2: 9,
    c: 10,
    c1: 11,
    c2: 12,
    p: 13,
    p1: 14,
    p1a: 15,
    p1b: 16,
    p2: 17,
    p2a: 18,
    p2b: 19,
    hd: 20,
    leaf: 21,
    domain_holder: 22,
    domain_child: 23,
    trigger: 24
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine), do: MachineState.new(machine)

  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  defp empty_acc, do: {MapSet.new(), MapSet.new(), %{}}

  # AC: "a plain atomic target enters exactly itself plus its ancestors up to
  # the domain"
  #
  # sabotage: `entry_set_for_transition/3`'s second `Enum.reduce/3` (the
  # effective-target ancestor walk) is deleted -> `a` (a1's compound parent,
  # bounded by the transition's domain `region`) never enters, reddening this
  # assertion.
  test "a plain atomic target enters exactly itself plus its ancestors up to the domain" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-a1")

    {states_to_enter, _default_entry, _history_content} =
      ExitEntry.compute_entry_set(ms, [transition])

    assert states_to_enter == MapSet.new([idx(:a1), idx(:a)])
  end

  # AC: "a compound target enters its initial descendant chain and is flagged
  # in states_for_default_entry"
  #
  # sabotage: `add_descendant_states_to_enter/3`'s compound arm drops the
  # `flag_default_entry/2` call -> `a` is entered but never flagged,
  # reddening this assertion.
  test "a compound target enters its initial descendant chain and is flagged for default entry" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-a")

    {states_to_enter, default_entry, _history_content} =
      ExitEntry.compute_entry_set(ms, [transition])

    assert states_to_enter == MapSet.new([idx(:a), idx(:a1)])
    assert default_entry == MapSet.new([idx(:a)])
  end

  # AC: "a parallel target enters every region, and each region's own initial
  # descendants"
  #
  # sabotage: `add_descendant_states_to_enter/3`'s parallel arm skips
  # `enter_uncovered_regions/3` entirely -> only `p` itself enters, and both
  # regions and their initial descendants are missing, reddening this
  # assertion.
  test "a parallel target enters every region and each region's initial descendants" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-p")

    {states_to_enter, default_entry, _history_content} =
      ExitEntry.compute_entry_set(ms, [transition])

    assert states_to_enter ==
             MapSet.new([idx(:p), idx(:p1), idx(:p1a), idx(:p2), idx(:p2a)])

    assert default_entry == MapSet.new([idx(:p1), idx(:p2)])
  end

  # AC: "a <parallel> with a <history> child treats the history child as
  # never-covered ground truth, not as a region" - `p` (the parallel entered
  # by `go-p`, above) has an unrecorded, unrelated `<history id="hd">` child
  # of its own. `getChildStates(state)` (Appendix D, "### function
  # getChildStates(state1)": "Returns a list containing all <state>,
  # <final>, and <parallel> children of state1") excludes `:history`
  # children by definition, so `hd` is never itself a region
  # `enter_uncovered_regions/3` walks; it stays unrecorded, and unrecorded
  # history registers `default_history_content` only when the history
  # pseudo-state itself is what gets entered (`enter_history_target/3`),
  # which never happens here because nothing targeted `hd`.
  #
  # sabotage: `region_indexes/2` (`Statifier.Interpreter.ExitEntry`) is
  # changed to call `Machine.children/2` instead of `Machine.child_states/2`
  # (regions become "every direct child", `:history` included) -> `hd` is
  # now an uncovered region of `p`, so `enter_uncovered_regions/3` calls
  # `add_descendant_states_to_enter/3` on it, which dispatches to
  # `enter_history_target/3` and wrongly registers
  # `default_history_content[idx(:p)]`, reddening this refutation. Left
  # unfixed, the same wrong registration makes an interpreter that runs the
  # returned `history_content` execute `hd`'s default transition's content
  # (e.g. an `<assign>`) even though `hd` was never entered.
  test "a <parallel> with a <history> child does not register default history content for entering it directly" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-p")

    {_states_to_enter, _default_entry, history_content} =
      ExitEntry.compute_entry_set(ms, [transition])

    refute Map.has_key?(history_content, idx(:p))
  end

  describe "a transition into one region of a parallel, from outside the parallel" do
    setup do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-p1a")

      {states_to_enter, default_entry, _history_content} =
        ExitEntry.compute_entry_set(ms, [transition])

      %{states_to_enter: states_to_enter, default_entry: default_entry}
    end

    # AC: "also enters the sibling regions ... and only the uncovered ones"
    #
    # sabotage: `enter_uncovered_regions/3` is changed to iterate only the
    # first child of `Machine.child_states/2` instead of all of them -> `p2`
    # (the second, uncovered region) never enters, reddening this assertion.
    test "enters the named target, its ancestors up to the domain, and the uncovered sibling region",
         %{states_to_enter: states_to_enter} do
      assert states_to_enter ==
               MapSet.new([idx(:p1a), idx(:p1), idx(:p), idx(:p2), idx(:p2a)])
    end

    # AC: "a state entered because it was named as a target is not flagged
    # for default entry, while its compound ancestors entered on the way
    # down are" - `p1a` is the named target (never flagged); `p1`, its plain
    # ancestor, is only ever `add_state`'d and is never flagged either; `p2`,
    # the sibling region swept in by the parallel ancestor `p`'s
    # `enter_uncovered_regions/3`, goes through the full
    # `add_descendant_states_to_enter/3` compound arm and *is* flagged.
    #
    # sabotage: `enter_uncovered_regions/3` drops the `covered?/3` test and
    # unconditionally calls `add_descendant_states_to_enter/3` on every
    # child, including the already-covered `p1` -> `p1` is wrongly flagged
    # too, reddening this assertion.
    test "flags only the uncovered sibling region, not the target itself or its covered ancestor",
         %{default_entry: default_entry} do
      assert default_entry == MapSet.new([idx(:p2)])
    end
  end

  # AC: "a targetless transition contributes nothing to any of the three
  # members"
  #
  # sabotage: `compute_entry_set/2`'s reduce seeds the accumulator with
  # `transition.source` before folding, regardless of whether the transition
  # has any targets -> `trigger` wrongly appears in `states_to_enter`,
  # reddening this refutation.
  test "a targetless transition contributes nothing to any of the three members" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-none")

    assert ExitEntry.compute_entry_set(ms, [transition]) == empty_acc()
  end

  # AC: "an internal transition's domain bounds the ancestor walk more
  # tightly than the external form of the same transition"
  #
  # sabotage: `add_ancestor_states_to_enter/4`'s `Enum.take_while/2` bound is
  # changed from `&(&1 != ancestor)` to a version that keeps going one step
  # past the boundary (includes `ancestor` itself) -> `domain_holder` wrongly
  # appears in the internal walk too, reddening the refutation below.
  test "internal transition's domain bounds the ancestor walk more tightly than the external form" do
    m = machine()
    ms = machine_state(m)
    internal = transition_named(m, "dom-internal")
    external = transition_named(m, "dom-external")

    internal_domain = Selection.get_transition_domain(ms, internal)
    external_domain = Selection.get_transition_domain(ms, external)

    assert internal_domain == idx(:domain_holder)
    assert external_domain == idx(:region)

    {internal_states, _default_entry, _history_content} =
      ExitEntry.add_ancestor_states_to_enter(ms, idx(:domain_child), internal_domain, empty_acc())

    {external_states, _default_entry, _history_content} =
      ExitEntry.add_ancestor_states_to_enter(ms, idx(:domain_child), external_domain, empty_acc())

    refute idx(:domain_holder) in internal_states
    assert idx(:domain_holder) in external_states
  end

  describe "history" do
    # AC: "a recorded shallow history restores the recorded children and
    # their descendants" and "a recorded history registers no
    # default_history_content"
    #
    # sabotage: `add_descendant_states_to_enter/3` registers default history
    # content on the recorded branch too (the `register_default_history_content/3`
    # call moves outside the `enter_history_target/3` `:error` case) -> the
    # `history_content == %{}` half of this assertion reddens.
    test "a recorded shallow history restores the recorded children (and their own current descendants)" do
      m = machine()

      ms = %{
        machine_state(m)
        | history_values: %{idx(:hs) => MapSet.new([idx(:a2)])}
      }

      {states_to_enter, _default_entry, history_content} =
        ExitEntry.add_descendant_states_to_enter(ms, idx(:hs), empty_acc())

      assert states_to_enter == MapSet.new([idx(:a2), idx(:a2x)])
      assert history_content == %{}
    end

    # AC: "a recorded deep history restores the recorded atomic set and every
    # ancestor between it and the history's parent (coherent parallel
    # restoration)"
    #
    # sabotage: `enter_restored/4`'s ancestor pass passes `nil` instead of
    # `parent_index` as the bound -> the walk no longer stops at `p`, pulling
    # in `region` (and the root) too, reddening the exact-set assertion.
    test "a recorded deep history restores its recorded atomic set with coherent parallel restoration" do
      m = machine()

      ms = %{
        machine_state(m)
        | history_values: %{idx(:hd) => MapSet.new([idx(:p1a), idx(:p2a)])}
      }

      {states_to_enter, default_entry, history_content} =
        ExitEntry.add_descendant_states_to_enter(ms, idx(:hd), empty_acc())

      assert states_to_enter ==
               MapSet.new([idx(:p1a), idx(:p2a), idx(:p1), idx(:p2)])

      assert default_entry == MapSet.new()
      assert history_content == %{}
    end

    # AC: "an unrecorded history follows its default transition's targets and
    # registers default_history_content keyed by the history state's parent"
    #
    # sabotage: `enter_history_target/3`'s `:error` branch registers
    # `history_index` instead of `history_state.parent` as the key ->
    # `history_content` comes back keyed by `hs` instead of `a`, reddening
    # this assertion.
    test "an unrecorded history follows its default transition's targets and registers default_history_content" do
      m = machine()
      ms = machine_state(m)
      default_t_index = Machine.at(m, idx(:hs)).history_default

      {states_to_enter, default_entry, history_content} =
        ExitEntry.add_descendant_states_to_enter(ms, idx(:hs), empty_acc())

      assert states_to_enter == MapSet.new([idx(:a1)])
      assert default_entry == MapSet.new()
      assert history_content == %{idx(:a) => default_t_index}
    end
  end
end
