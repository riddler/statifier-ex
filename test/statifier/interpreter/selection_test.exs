defmodule Statifier.Interpreter.SelectionTest do
  use ExUnit.Case, async: true

  alias Predicator.Errors.UndefinedVariableError
  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Event
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

  # Hand-drawn from `@document`, depth-first, document order (verified
  # against `machine.id_to_index` while authoring this fixture):
  #
  #  0 scxml (root)
  #  1   event_state          -- matched-event selection, non-matching event
  #  2   ancestor             -- child preempts ancestor
  #  3     descendant
  #  4   multi                -- sibling document-order priority (two txns)
  #  5   condfail             -- written cond, evaluates false -> not selected
  #  6   condtrue             -- written cond, evaluates true -> selected
  #  7   condpass             -- no cond -> selected
  #  8   eventless_state      -- eventless vs event-bearing
  #  9   ancestor_for_dedup   -- shared-ancestor transition dedup
  # 10     dedup_parallel      (children [11,13], last 14)
  # 11       dedup1
  # 12         dedup1a
  # 13       dedup2
  # 14         dedup2a
  # 15   regression_parallel  -- the named v1 parallel-regions regression
  # 16     preg1               (children [17,18], last 18)
  # 17       preg1a             (transition event="go" internal -> preg1b)
  # 18       preg1b
  # 19     preg2               (children [20,21], last 21)
  # 20       preg2a             (transition event="go" internal -> preg2b)
  # 21       preg2b
  # 22   unrelated_go          (transition event="go" internal -> its child)
  # 23     unrelated_go_child
  # 24   targetless_holder     -- targetless transition
  # 25   P                     -- descendant/ancestor conflict fixture
  # 26     L                    (children [27,28], last 28)
  # 27       l1                  (transition external -> l2, sibling conflict)
  # 28       l2                  (transition external -> l1, sibling conflict)
  # 29     R                    (children [30,31], last 31)
  # 30       r1
  # 31       r2
  # 32   tgt                   -- generic transition target, never entered
  # 33   tgt-a
  # 34   tgt-b
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
          <transition event="cond-evt" cond="false" target="tgt"/>
      </state>
      <state id="condtrue">
          <transition event="cond-evt-true" cond="true" target="tgt"/>
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
    condtrue: 6,
    condpass: 7,
    eventless_state: 8,
    ancestor_for_dedup: 9,
    dedup_parallel: 10,
    dedup1: 11,
    dedup1a: 12,
    dedup2: 13,
    dedup2a: 14,
    regression_parallel: 15,
    preg1: 16,
    preg1a: 17,
    preg1b: 18,
    preg2: 19,
    preg2a: 20,
    preg2b: 21,
    unrelated_go: 22,
    unrelated_go_child: 23,
    targetless_holder: 24,
    p: 25,
    l: 26,
    l1: 27,
    l2: 28,
    r: 29,
    r1: 30,
    r2: 31,
    tgt: 32,
    tgt_a: 33,
    tgt_b: 34
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

  # A second, narrower document just for `condition_match/2`'s own unit
  # coverage below - separate from `@document` so its cond expressions (and
  # any bound datamodel) do not disturb the document-order indexes the rest
  # of this file's sabotage comments and `@indexes` map depend on.
  @cond_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="cond_s1">
      <state id="cond_s1">
          <transition event="nilcond" target="cond_s2"/>
          <transition event="truecond" cond="true" target="cond_s2"/>
          <transition event="falsecond" cond="false" target="cond_s2"/>
          <transition event="boundgt3" cond="x > 3" target="cond_s2"/>
          <transition event="boundgt9" cond="x > 9" target="cond_s2"/>
          <transition event="unbound" cond="nope" target="cond_s2"/>
          <transition event="nonbool" cond="1" target="cond_s2"/>
          <transition event="inconfig" cond="In('cond_s1')" target="cond_s2"/>
          <transition event="notinconfig" cond="In('cond_s2')" target="cond_s2"/>
          <transition event="innotdeclared" cond="In('no-such-state')" target="cond_s2"/>
      </state>
      <state id="cond_s2"/>
  </scxml>
  """

  defp cond_machine, do: compile!(@cond_document)

  defp cond_transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  defp cond_machine_state(machine, configuration, opts \\ []) do
    %{MachineState.new(machine, opts) | configuration: MapSet.new(configuration)}
  end

  defp idx_cond(machine, id) do
    {:ok, index} = Machine.index(machine, id)
    index
  end

  describe "condition_match/2" do
    # sabotage: `evaluate_cond/2`'s `cond: nil` clause is changed from
    # `{:ok, true}` to `{:error, :nope}` -> this reddens because a `nil` cond
    # no longer unconditionally passes.
    test "cond: nil returns {:ok, true} with an empty datamodel" do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])
      transition = cond_transition_named(m, "nilcond")

      assert Selection.condition_match(ms, transition) == {:ok, true}
    end

    # sabotage: `evaluate_cond/2`'s `{:ok, true} -> {:ok, true}` clause is
    # changed to `{:ok, true} -> {:ok, false}` -> this reddens because a
    # written `cond="true"` no longer reports itself enabled.
    test ~s(cond="true" returns {:ok, true}) do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])
      transition = cond_transition_named(m, "truecond")

      assert Selection.condition_match(ms, transition) == {:ok, true}
    end

    # sabotage: `evaluate_cond/2`'s `{:ok, false} -> {:ok, false}` clause is
    # changed to `{:ok, false} -> {:ok, true}` -> this reddens because a
    # written `cond="false"` no longer reports itself disabled.
    test ~s(cond="false" returns {:ok, false}) do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])
      transition = cond_transition_named(m, "falsecond")

      assert Selection.condition_match(ms, transition) == {:ok, false}
    end

    # sabotage: `evaluate_cond/2`'s compiled-cond clause calls
    # `Evaluator.evaluate/2` with a hardcoded empty context instead of the
    # one built from `machine_state` -> this reddens because `x > 3` can no
    # longer see the bound `x` and errors as unbound instead of returning
    # `{:ok, true}`.
    test "a cond over bound data evaluates against the machine_state's datamodel" do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")], datamodel: %{"x" => 5})
      gt3 = cond_transition_named(m, "boundgt3")
      gt9 = cond_transition_named(m, "boundgt9")

      assert Selection.condition_match(ms, gt3) == {:ok, true}
      assert Selection.condition_match(ms, gt9) == {:ok, false}
    end

    # sabotage: `evaluate_cond/2`'s `{:error, %Evaluator.Error{} = error} ->
    # {:error, error}` clause is changed to `{:error, _error} -> {:ok, false}`
    # -> this reddens because an unbound-variable cond is swallowed into a
    # falsy value instead of surfacing as an error.
    test "a cond naming an unbound variable returns an Evaluator.Error with a non-nil span" do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])
      transition = cond_transition_named(m, "unbound")

      assert {:error,
              %Evaluator.Error{
                source: "nope",
                error: %UndefinedVariableError{},
                span: span
              }} = Selection.condition_match(ms, transition)

      refute is_nil(span)
    end

    # sabotage: `evaluate_cond/2`'s `{:ok, other} -> {:error,
    # {:non_boolean_cond, other}}` clause is changed to
    # `{:ok, other} -> {:ok, other}` (D1's rejected shape - truthy
    # non-boolean) -> this reddens because `cond="1"` now returns `{:ok, 1}`
    # instead of an error.
    test "a non-boolean cond returns {:error, {:non_boolean_cond, value}}" do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])
      transition = cond_transition_named(m, "nonbool")

      assert Selection.condition_match(ms, transition) == {:error, {:non_boolean_cond, 1}}
    end

    # sabotage: `Evaluator.context/1`'s `In/1` host function's matched-id
    # branch is swapped to always return `{:ok, false}` -> this reddens
    # because `In('cond_s1')` against a configuration containing `cond_s1`
    # comes back false instead of true.
    test "a cond calling In/1 answers against the machine_state's configuration" do
      m = cond_machine()
      ms = cond_machine_state(m, [idx_cond(m, "cond_s1")])

      in_config = cond_transition_named(m, "inconfig")
      not_in_config = cond_transition_named(m, "notinconfig")
      not_declared = cond_transition_named(m, "innotdeclared")

      assert Selection.condition_match(ms, in_config) == {:ok, true}
      assert Selection.condition_match(ms, not_in_config) == {:ok, false}
      assert Selection.condition_match(ms, not_declared) == {:ok, false}
    end
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

    # sabotage: `evaluate_cond/2`'s `{:ok, false} -> {:ok, false}` clause is
    # changed to `{:ok, false} -> {:ok, true}` -> this reddens because a cond
    # that genuinely evaluates false now wrongly selects its transition.
    test "a transition whose cond evaluates false is not selected" do
      m = machine()
      ms = machine_state(m, [idx(:condfail)])

      assert {_ms, []} = Selection.select_transitions(ms, Event.external("cond-evt"))
    end

    # sabotage: `evaluate_cond/2`'s `{:ok, true} -> {:ok, true}` clause is
    # changed to `{:ok, true} -> {:ok, false}` -> this reddens because a cond
    # that genuinely evaluates true no longer selects its transition.
    test "a transition whose cond evaluates true is selected" do
      m = machine()
      ms = machine_state(m, [idx(:condtrue)])

      {_ms, transitions} = Selection.select_transitions(ms, Event.external("cond-evt-true"))

      assert [%{events: [["cond-evt-true"]]}] = transitions
    end

    # sabotage: `transition_enabled?/3`'s event-matched clause drops the
    # `condition_match(machine_state, transition) == {:ok, true}` conjunct
    # -> this passes regardless (nil cond always matches), so instead this
    # sabotages the twin: `evaluate_cond/2`'s `cond: nil` clause is changed
    # from `{:ok, true}` to `{:error, :nope}` -> this reddens because a
    # transition with no cond is no longer selected either.
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
