defmodule Statifier.Interpreter.SelectionTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Event
  alias Statifier.Interpreter.Selection
  alias Statifier.Lowering
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

  # Hand-drawn from `@document`, depth-first, document order (verified
  # against `machine.id_to_index` while authoring this fixture):
  #
  #  0 scxml (root)
  #  1   event_state          -- matched-event selection, non-matching event
  #  2   ancestor             -- child preempts ancestor
  #  3     descendant
  #  4   multi                -- sibling document-order priority (two txns)
  #  5   condfail             -- written cond -> not selected
  #  6   condpass             -- no cond -> selected
  #  7   eventless_state      -- eventless vs event-bearing
  #  8   ancestor_for_dedup   -- shared-ancestor transition dedup
  #  9     dedup_parallel      (children [10,12], last 13)
  # 10       dedup1
  # 11         dedup1a
  # 12       dedup2
  # 13         dedup2a
  # 14   regression_parallel  -- the named v1 parallel-regions regression
  # 15     preg1               (children [16,17], last 17)
  # 16       preg1a             (transition event="go" internal -> preg1b)
  # 17       preg1b
  # 18     preg2               (children [19,20], last 20)
  # 19       preg2a             (transition event="go" internal -> preg2b)
  # 20       preg2b
  # 21   unrelated_go          (transition event="go" internal -> its child)
  # 22     unrelated_go_child
  # 23   targetless_holder     -- targetless transition
  # 24   P                     -- descendant/ancestor conflict fixture
  # 25     L                    (children [26,27], last 27)
  # 26       l1                  (transition external -> l2, sibling conflict)
  # 27       l2                  (transition external -> l1, sibling conflict)
  # 28     R                    (children [29,30], last 30)
  # 29       r1
  # 30       r2
  # 31   tgt                   -- generic transition target, never entered
  # 32   tgt-a
  # 33   tgt-b
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="event_state">
      <state id="event_state">
          <transition event="matched" target="tgt"/>
      </state>
      <state id="ancestor">
          <transition event="shared" target="tgt"/>
          <state id="descendant">
              <transition event="shared" target="tgt"/>
          </state>
      </state>
      <state id="multi">
          <transition event="multi-evt" target="tgt-a"/>
          <transition event="multi-evt" target="tgt-b"/>
      </state>
      <state id="condfail">
          <transition event="cond-evt" cond="true" target="tgt"/>
      </state>
      <state id="condpass">
          <transition event="cond-evt2" target="tgt"/>
      </state>
      <state id="eventless_state">
          <transition target="tgt"/>
          <transition event="has-event" target="tgt"/>
      </state>
      <state id="ancestor_for_dedup">
          <transition event="dedup-evt"/>
          <parallel id="dedup_parallel">
              <state id="dedup1">
                  <state id="dedup1a"/>
              </state>
              <state id="dedup2">
                  <state id="dedup2a"/>
              </state>
          </parallel>
      </state>
      <parallel id="regression_parallel">
          <state id="preg1">
              <state id="preg1a">
                  <transition event="go" target="preg1b" type="internal"/>
              </state>
              <state id="preg1b"/>
          </state>
          <state id="preg2">
              <state id="preg2a">
                  <transition event="go" target="preg2b" type="internal"/>
              </state>
              <state id="preg2b"/>
          </state>
      </parallel>
      <state id="unrelated_go">
          <transition event="go" target="unrelated_go_child" type="internal"/>
          <state id="unrelated_go_child"/>
      </state>
      <state id="targetless_holder">
          <transition event="tless-evt"/>
      </state>
      <state id="P">
          <transition event="p-evt" target="l1" type="internal"/>
          <state id="L">
              <transition event="l-evt" target="l2" type="internal"/>
              <state id="l1">
                  <transition event="l1-evt" target="l2" type="external"/>
              </state>
              <state id="l2">
                  <transition event="l2-evt" target="l1" type="external"/>
              </state>
          </state>
          <state id="R">
              <transition event="r-evt" target="r1" type="internal"/>
              <state id="r1"/>
              <state id="r2"/>
          </state>
      </state>
      <state id="tgt"/>
      <state id="tgt-a"/>
      <state id="tgt-b"/>
  </scxml>
  """

  @indexes %{
    event_state: 1,
    ancestor: 2,
    descendant: 3,
    multi: 4,
    condfail: 5,
    condpass: 6,
    eventless_state: 7,
    ancestor_for_dedup: 8,
    dedup_parallel: 9,
    dedup1: 10,
    dedup1a: 11,
    dedup2: 12,
    dedup2a: 13,
    regression_parallel: 14,
    preg1: 15,
    preg1a: 16,
    preg1b: 17,
    preg2: 18,
    preg2a: 19,
    preg2b: 20,
    unrelated_go: 21,
    unrelated_go_child: 22,
    targetless_holder: 23,
    p: 24,
    l: 25,
    l1: 26,
    l2: 27,
    r: 28,
    r1: 29,
    r2: 30,
    tgt: 31,
    tgt_a: 32,
    tgt_b: 33
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration) do
    %{MachineState.new(machine) | configuration: MapSet.new(configuration)}
  end

  # Mirrors `selection_domain_test.exs`'s `transition_named/2`: finds the
  # transition among `machine`'s own transitions whose single event
  # descriptor is `event_name`. Every transition under test here has a
  # distinct `event` attribute purely as a lookup key.
  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  describe "select_transitions/2" do
    # sabotage: `first_matching_transition/4`'s `Enum.find/2` predicate is
    # changed from `transition_enabled?/3` to a constant `false` -> this
    # reddens because nothing is ever selected.
    test "an event-matched transition on the atomic state itself is selected" do
      m = machine()
      ms = machine_state(m, [idx(:event_state)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("matched"))

      assert [%{events: [["matched"]]}] = transitions
    end

    # sabotage: `transition_enabled?/3`'s event-matched clause calls
    # `NameMatch.name_match?/2` but ignores its result (replaced with the
    # literal `true`) -> this reddens because a non-matching event now
    # wrongly selects the transition anyway.
    test "a non-matching event selects nothing" do
      m = machine()
      ms = machine_state(m, [idx(:event_state)])

      assert {_ms, []} = Selection.select_transitions(ms, Event.external("nonexistent"))
    end

    # sabotage: `selected_for_atomic_state/3` walks
    # `Machine.proper_ancestors(machine, state_index)` only, dropping the
    # `state_index` itself from the head of the list -> this reddens because
    # the child's own transition is skipped and the ancestor's is selected
    # instead.
    test "child preempts ancestor" do
      m = machine()
      ms = machine_state(m, [idx(:descendant)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("shared"))

      assert [%{source: source}] = transitions
      assert source == idx(:descendant)
    end

    # sabotage: `first_matching_transition/4` reverses the state's own
    # `transitions` list before searching (`Enum.reverse/1` inserted before
    # `Enum.map/2`) -> this reddens because the second-written transition
    # (targeting `tgt-b`) wins instead of the first.
    test "sibling document-order priority: the first transition in document order wins" do
      m = machine()
      ms = machine_state(m, [idx(:multi)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("multi-evt"))

      assert [%{targets: [target]}] = transitions
      assert target == idx(:tgt_a)
    end

    # sabotage: `condition_match/2`'s second clause (`%Transition{}` with a
    # written `cond`) is changed from `{:error, {:unsupported, :cond}}` to
    # `{:ok, true}` -> this reddens because the cond-bearing transition is
    # wrongly selected.
    test "a transition with a written cond is not selected" do
      m = machine()
      ms = machine_state(m, [idx(:condfail)])

      assert {_ms, []} = Selection.select_transitions(ms, Event.external("cond-evt"))
    end

    # sabotage: `transition_enabled?/3`'s event-matched clause drops the
    # `condition_match(machine_state, transition) == {:ok, true}` conjunct
    # -> this passes regardless (nil cond always matches), so instead this
    # sabotages the twin: `condition_match/2`'s first clause (`cond: nil`) is
    # changed to `{:error, :nope}` -> this reddens because a transition with
    # no cond is no longer selected either.
    test "a transition with no cond is selected" do
      m = machine()
      ms = machine_state(m, [idx(:condpass)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("cond-evt2"))

      assert [%{events: [["cond-evt2"]]}] = transitions
    end

    # sabotage: `transition_enabled?/3`'s `events: []` guard clause is
    # deleted and its event-matched clause is widened to
    # `transition.events == [] or NameMatch.name_match?(...)` -> this
    # reddens because the eventless transition (document-order first on
    # `eventless_state`) is now wrongly selected ahead of the real
    # `"has-event"` match.
    test "select_transitions/2 ignores an eventless transition" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_state)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("has-event"))

      assert [%{events: [["has-event"]]}] = transitions
    end

    # sabotage: `select_transitions/2` is changed to return `machine_state`
    # with its `microstep` incremented (`MachineState.begin_microstep/1`)
    # before the tuple is built -> this reddens because the returned
    # machine_state no longer `==` the input.
    test "the machine_state comes back unchanged" do
      m = machine()
      ms = machine_state(m, [idx(:event_state)])

      {returned_ms, _transitions} = Selection.select_transitions(ms, Event.external("matched"))

      assert returned_ms == ms
    end

    # sabotage: `select_transitions/2`'s final `Enum.uniq_by(& &1.t_index)`
    # is deleted -> this reddens because `ancestor_for_dedup`'s targetless
    # transition (whose empty exit set never conflicts with itself, so
    # `remove_conflicting_transitions/2` cannot mask the missing dedupe) is
    # counted twice, once per region's atomic state, instead of once.
    test "a transition shared by two atomic states' ancestor walk appears once" do
      m = machine()
      ms = machine_state(m, [idx(:dedup1a), idx(:dedup2a)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("dedup-evt"))

      assert [%{events: [["dedup-evt"]]}] = transitions
    end

    # sabotage: `remove_conflicting_transitions/2`'s conflict test
    # (`conflicts?/3`) is replaced with a function that always returns
    # `true` (the v1 "one group" collapse: any two enabled transitions are
    # treated as conflicting) -> this reddens because only one of the three
    # transitions below survives instead of all three.
    #
    # This is the named regression test for v1's parallel-region conflict
    # bug (`../statifier/lib/statifier/interpreter/transition_resolver.ex:142-156`):
    # v1 reduced every transition's exit set to a boolean "does it leave the
    # nearest parallel ancestor", grouped transitions into "exits parallel"
    # versus "stays inside", and collapsed the whole microstep to the
    # earliest transition whenever both groups were non-empty - discarding
    # every other enabled transition, including ones in unrelated parallel
    # regions whose exit sets never actually intersected.
    test "parallel regions keep non-conflicting transitions" do
      m = machine()

      ms =
        machine_state(m, [idx(:preg1a), idx(:preg2a), idx(:unrelated_go_child)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("go"))

      sources = transitions |> Enum.map(& &1.source) |> Enum.sort()
      assert sources == Enum.sort([idx(:preg1a), idx(:preg2a), idx(:unrelated_go)])
    end
  end

  describe "select_eventless_transitions/1" do
    # sabotage: `select_eventless_transitions/1` passes a non-`nil`
    # `event_tokens` (`[]` instead of `nil`) to `selected_for_atomic_state/3`
    # -> this reddens because `transition_enabled?/3`'s eventless clause no
    # longer matches (it requires `nil`), so nothing is selected.
    test "selects a transition with no event attribute and ignores an event-bearing one" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_state)])

      {_ms, transitions} = Selection.select_eventless_transitions(ms)

      assert [%{events: []}] = transitions
    end

    # sabotage: `select_eventless_transitions/1` is changed to return
    # `machine_state` with `running: false` set before the tuple is built
    # -> this reddens because the returned machine_state no longer `==` the
    # input.
    test "the machine_state comes back unchanged" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_state)])

      {returned_ms, _transitions} = Selection.select_eventless_transitions(ms)

      assert returned_ms == ms
    end
  end

  describe "remove_conflicting_transitions/2" do
    # sabotage: `conflict_step/5`'s `Machine.descendant?(machine_state.machine,
    # t1.source, t2.source)` arguments are swapped (`t2.source, t1.source`)
    # -> this reddens because the ancestor-sourced transition would then
    # wrongly win over the descendant-sourced one.
    test "descendant preempts ancestor on conflict, regardless of list order" do
      m = machine()
      ms = machine_state(m, [idx(:p), idx(:l), idx(:l1), idx(:l2), idx(:r), idx(:r1), idx(:r2)])
      t_l = transition_named(m, "l-evt")
      t_p = transition_named(m, "p-evt")

      assert Selection.remove_conflicting_transitions(ms, [t_p, t_l]) == [t_l]
      assert Selection.remove_conflicting_transitions(ms, [t_l, t_p]) == [t_l]
    end

    # sabotage: `conflict_step/5`'s ancestor-sourced branch
    # (`{:halt, {:preempted, filtered}}`, "otherwise t1 is preempted") is
    # changed to `{:cont, {:keep, [t2 | to_remove]}}` - the same outcome as
    # the descendant-sourced branch - so every conflict favors whichever
    # transition is processed later instead of whichever came first -> this
    # reddens because the later-listed sibling wins both orderings instead
    # of the earlier one winning both.
    test "document-order priority on conflict between unrelated sources" do
      m = machine()
      ms = machine_state(m, [idx(:l), idx(:l1), idx(:l2)])
      t_l1 = transition_named(m, "l1-evt")
      t_l2 = transition_named(m, "l2-evt")

      assert Selection.remove_conflicting_transitions(ms, [t_l1, t_l2]) == [t_l1]
      assert Selection.remove_conflicting_transitions(ms, [t_l2, t_l1]) == [t_l2]
    end

    # sabotage: `conflicts?/3` treats an empty exit set on either side as
    # conflicting-with-everything (`MapSet.size(exit1) == 0 or
    # MapSet.size(exit2) == 0 or not MapSet.disjoint?(exit1, exit2)`) instead
    # of disjointness alone -> this reddens because the targetless
    # transition's empty exit set now wrongly conflicts with `l1-evt`'s, so
    # only one of the two survives instead of both.
    test "a targetless transition conflicts with nothing" do
      m = machine()
      ms = machine_state(m, [idx(:l), idx(:l1), idx(:l2)])
      t_targetless = transition_named(m, "tless-evt")
      t_l1 = transition_named(m, "l1-evt")

      assert Selection.remove_conflicting_transitions(ms, [t_targetless, t_l1]) == [
               t_targetless,
               t_l1
             ]
    end

    # sabotage: `resolve_against_filtered/3`'s halted-branch `{:halt,
    # {:preempted, filtered}}` is changed to `{:halt, {:preempted, []}}`
    # (drops every earlier survivor instead of leaving them untouched) ->
    # this reddens because `t_l` disappears from the final result even
    # though only `t_p` was preempted.
    test "a transition preempted by an earlier one does not itself remove a third" do
      m = machine()
      ms = machine_state(m, [idx(:p), idx(:l), idx(:l1), idx(:l2), idx(:r), idx(:r1), idx(:r2)])
      t_l = transition_named(m, "l-evt")
      t_p = transition_named(m, "p-evt")
      t_r = transition_named(m, "r-evt")

      assert Selection.remove_conflicting_transitions(ms, [t_l, t_p, t_r]) == [t_l, t_r]
    end
  end
end
