defmodule Statifier.Interpreter.ExitEntryEnterTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Param
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # `@document` deliberately contains an id-less compound wrapping a
  # `<final>` (index 20 below), the one shape
  # `raise_parent_completion/3`'s `_no_id` arm exists for. st-t8w makes
  # `Statifier.Validator` refuse exactly that document, so this fixture
  # compiles through Parser -> Lowering -> Compiler and skips the
  # validator: the guard it covers is defense in depth behind a gate that
  # rejects the input, and a test for it cannot pass through that gate by
  # construction.
  defp compile_unvalidated!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order. `<initial>`,
  # `<transition>`, and `<donedata>`/`<content>` elements contribute no
  # state index of their own.
  #
  #  0 scxml (root; parent: nil, id: nil)
  #  1   region
  #  2     combo               (compound; onentry; <initial> -> combo_a w/ content)
  #  3       combo_a
  #  4       combo_b
  #  5       combo_hist        (history, shallow, default -> combo_b w/ content)
  #  6     deep                (compound; onentry)
  #  7       deep_child        (onentry)
  #  8     compound_final      (compound; no history/onentry)
  #  9       cf_active
  # 10       cf_done            (final)
  # 11     par                 (parallel)
  # 12       reg1               (compound; no <initial> -> reg1_active by default)
  # 13         reg1_active
  # 14         reg1_final       (final)
  # 15       reg2               (compound; no <initial> -> reg2_active by default)
  # 16         reg2_active
  # 17         reg2_final       (final)
  # 18     donedata_holder     (compound)
  # 19       dd_final           (final; static donedata "42")
  # 20     (unnamed compound - no id; intentionally validator-rejected -
  #        st-t8w makes `Statifier.Validator` refuse this shape, so this
  #        fixture is compiled through `compile_unvalidated!/1`, not
  #        `compile!/1`; do not "fix" this by giving the state an id)
  # 21       noid_final         (final)
  # 22     noid_par            (parallel; no id - covers
  #        `maybe_raise_grandparent_completion/3`'s own `_no_id` arm, the
  #        grandparent-side twin of index 20's parent-side coverage; kept
  #        distinct from `par` above so completing `par`'s regions is not
  #        entangled with this fixture)
  # 23       noid_par_reg1      (compound; no <initial> -> default child)
  # 24         noid_par_reg1_active
  # 25         noid_par_reg1_final (final)
  # 26       noid_par_reg2      (compound; no <initial> -> default child)
  # 27         noid_par_reg2_active
  # 28         noid_par_reg2_final (final)
  # 29     ce_holder           (compound)
  # 30       ce_final           (final; donedata content expr="1 + 1", succeeds)
  # 31     ce_fail_holder      (compound)
  # 32       ce_fail_final      (final; donedata content expr="undeclared_var", fails)
  # 33     trigger             (go-* transitions)
  # 34   top_final              (final; parent 0 - top-level)
  #
  # `reg1`/`reg2` each carry a non-final default child so that sweeping an
  # "uncovered region" of the parallel (`enter_uncovered_regions/3`, pulled
  # in whenever a transition targets only one region directly) enters that
  # region's *default* state, not its `<final>` - otherwise every
  # single-region transition below would complete the whole parallel in one
  # step, which is not what these tests are isolating.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="region">
      <state id="region">
          <state id="combo">
              <onentry>
                  <log label="combo-enter"/>
              </onentry>
              <initial>
                  <transition target="combo_a">
                      <log label="combo-initial-content"/>
                  </transition>
              </initial>
              <state id="combo_a"/>
              <state id="combo_b"/>
              <history id="combo_hist" type="shallow">
                  <transition target="combo_b">
                      <log label="combo-hist-content"/>
                  </transition>
              </history>
          </state>
          <state id="deep">
              <onentry>
                  <log label="deep-enter"/>
              </onentry>
              <state id="deep_child">
                  <onentry>
                      <log label="deep-child-enter"/>
                  </onentry>
              </state>
          </state>
          <state id="compound_final">
              <state id="cf_active"/>
              <final id="cf_done"/>
          </state>
          <parallel id="par">
              <state id="reg1">
                  <state id="reg1_active"/>
                  <final id="reg1_final"/>
              </state>
              <state id="reg2">
                  <state id="reg2_active"/>
                  <final id="reg2_final"/>
              </state>
          </parallel>
          <state id="donedata_holder">
              <final id="dd_final">
                  <donedata>
                      <content>42</content>
                  </donedata>
              </final>
          </state>
          <state>
              <final id="noid_final"/>
          </state>
          <parallel>
              <state id="noid_par_reg1">
                  <state id="noid_par_reg1_active"/>
                  <final id="noid_par_reg1_final"/>
              </state>
              <state id="noid_par_reg2">
                  <state id="noid_par_reg2_active"/>
                  <final id="noid_par_reg2_final"/>
              </state>
          </parallel>
          <state id="ce_holder">
              <final id="ce_final">
                  <donedata>
                      <content expr="1 + 1"/>
                  </donedata>
              </final>
          </state>
          <state id="ce_fail_holder">
              <final id="ce_fail_final">
                  <donedata>
                      <content expr="undeclared_var"/>
                  </donedata>
              </final>
          </state>
          <state id="trigger">
              <transition event="go-combo" target="combo"/>
              <transition event="go-combo-hist" target="combo_hist"/>
              <transition event="go-combo-a" target="combo_a"/>
              <transition event="go-deep-child" target="deep_child"/>
              <transition event="go-cf-done" target="cf_done"/>
              <transition event="go-reg1-final" target="reg1_final"/>
              <transition event="go-reg2-final" target="reg2_final"/>
              <transition event="go-dd-final" target="dd_final"/>
              <transition event="go-noid-final" target="noid_final"/>
              <transition event="go-noid-par-reg1-final" target="noid_par_reg1_final"/>
              <transition event="go-noid-par-reg2-final" target="noid_par_reg2_final"/>
              <transition event="go-ce-final" target="ce_final"/>
              <transition event="go-ce-fail-final" target="ce_fail_final"/>
              <transition event="go-top-final" target="top_final"/>
          </state>
      </state>
      <final id="top_final"/>
  </scxml>
  """

  @indexes %{
    region: 1,
    combo: 2,
    combo_a: 3,
    combo_b: 4,
    combo_hist: 5,
    deep: 6,
    deep_child: 7,
    compound_final: 8,
    cf_active: 9,
    cf_done: 10,
    par: 11,
    reg1: 12,
    reg1_active: 13,
    reg1_final: 14,
    reg2: 15,
    reg2_active: 16,
    reg2_final: 17,
    donedata_holder: 18,
    dd_final: 19,
    noid_final: 21,
    noid_par: 22,
    noid_par_reg1: 23,
    noid_par_reg1_active: 24,
    noid_par_reg1_final: 25,
    noid_par_reg2: 26,
    noid_par_reg2_active: 27,
    noid_par_reg2_final: 28,
    ce_holder: 29,
    ce_final: 30,
    ce_fail_holder: 31,
    ce_fail_final: 32,
    trigger: 33,
    top_final: 34
  }

  defp machine, do: compile_unvalidated!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration \\ [], opts \\ [trace: true]) do
    %{
      MachineState.new(machine, opts)
      | configuration: MapSet.new(configuration)
    }
  end

  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  # AC: "Exit order reverse document order, entry order document order,
  # asserted by tests"
  #
  # sabotage: `enter_states/2` sorts `states_to_enter` with
  # `Machine.exit_order/2` instead of `Machine.document_order/2` -> entry
  # order becomes descending instead of ascending, reddening this
  # assertion.
  test "entry order is strictly ascending index" do
    m = machine()
    ms = machine_state(m)
    transition = transition_named(m, "go-cf-done")

    {result, effects} = ExitEntry.enter_states(ms, [transition])

    assert [{:trace, %Effect.Trace.EntrySet{indexes: indexes}}] = effects
    assert indexes == [idx(:compound_final), idx(:cf_done)]
    assert MapSet.member?(result.configuration, idx(:cf_done))
  end

  # AC: "the configuration after enter_states/2 is the original plus exactly
  # the entry set"
  #
  # sabotage: `arrive/3` is changed to `MapSet.put/2` the state into a copy
  # of `machine_state.configuration` that is discarded (the reduce's
  # accumulator is never actually updated with the new configuration) ->
  # `result.configuration` would come back unchanged from the original,
  # reddening this assertion.
  test "the configuration after enter_states/2 is the original plus exactly the entry set" do
    m = machine()
    ms = machine_state(m, [idx(:region), idx(:trigger)])
    transition = transition_named(m, "go-cf-done")

    {result, _effects} = ExitEntry.enter_states(ms, [transition])

    assert result.configuration ==
             MapSet.union(ms.configuration, MapSet.new([idx(:compound_final), idx(:cf_done)]))
  end

  describe "the EntrySet trace" do
    # sabotage: `enter_states/2`'s `Effect.trace/3` call passes
    # `indexes: Machine.exit_order(machine, states_to_enter)` instead of
    # the already-ordered `entry_order` -> the trace payload's indexes come
    # back descending instead of ascending, reddening this assertion.
    test "is emitted with indexes in entry order when trace: true" do
      m = machine()
      ms = machine_state(m, [], trace: true)
      transition = transition_named(m, "go-cf-done")

      {_result, effects} = ExitEntry.enter_states(ms, [transition])

      assert [{:trace, %Effect.Trace.EntrySet{indexes: indexes}}] = effects
      assert indexes == Machine.document_order(m, [idx(:compound_final), idx(:cf_done)])
    end

    # sabotage: `enter_states/2`'s `Effect.trace/3` call site is replaced
    # with a bare list literal `[{:trace, Effect.Trace.EntrySet.new(...)}]`
    # (bypassing the `machine_state.trace` gate) -> a trace effect is
    # emitted even with `trace: false`, reddening this refutation.
    test "no trace effect at all when trace: false" do
      m = machine()
      ms = machine_state(m, [], trace: false)
      transition = transition_named(m, "go-cf-done")

      {_result, effects} = ExitEntry.enter_states(ms, [transition])

      refute Enum.any?(effects, &Effect.trace?/1)
    end
  end

  describe "per-state block sources (onentry, default entry, default history content)" do
    # AC: "the ordering of block invocations per state is onentry, then
    # default entry, then default history content" - `execute_block/3` is a
    # no-op stub, so no test here can observe a block actually *running*;
    # what is decidable without execution is that
    # `combo` carries three distinct, non-empty content sources and that
    # `enter_states/2`'s bookkeeping flags/registers exactly the ones
    # `arrive/3` is documented to run in that order - `run_onentry_blocks/2`
    # always runs first (unconditional), `run_default_entry/3`'s two
    # branches run next in the order `arrive/3`'s doc states.
    #
    # sabotage: `add_descendant_states_to_enter/3`'s compound arm drops the
    # `flag_default_entry/2` call -> `combo` is entered but never flagged,
    # reddening the `default_entry` assertion below.
    test "combo carries onentry content, is flagged for default entry, and registers default history content" do
      m = machine()
      ms = machine_state(m)
      to_combo = transition_named(m, "go-combo")
      to_combo_hist = transition_named(m, "go-combo-hist")

      onentry_content = Machine.at(m, idx(:combo)).onentry |> Enum.flat_map(& &1.content)
      initial_t = Machine.at(m, idx(:combo)).initial_transition
      initial_content = Machine.transition(m, initial_t).content

      {_states_to_enter, default_entry, history_content} =
        ExitEntry.compute_entry_set(ms, [to_combo, to_combo_hist])

      assert onentry_content != []
      assert initial_content != []
      assert MapSet.member?(default_entry, idx(:combo))

      assert {:ok, hist_t} = Map.fetch(history_content, idx(:combo))
      hist_content = Machine.transition(m, hist_t).content
      assert hist_content != []

      # The three content sources are genuinely distinct c_index lists, not
      # the same block read three times.
      assert Enum.uniq([onentry_content, initial_content, hist_content]) ==
               [onentry_content, initial_content, hist_content]
    end

    # AC: "default-entry content is invoked only for a state flagged in
    # states_for_default_entry"
    #
    # sabotage: `add_descendant_states_to_enter/3`'s history arm is changed
    # to also call `flag_default_entry/2` on the history's parent -> `combo`
    # would wrongly be flagged even when only its history child (not combo
    # itself) is targeted, reddening the refutation below.
    test "a state entered only through its history child is not flagged for default entry" do
      m = machine()
      ms = machine_state(m)
      to_combo_hist = transition_named(m, "go-combo-hist")

      {states_to_enter, default_entry, _history_content} =
        ExitEntry.compute_entry_set(ms, [to_combo_hist])

      assert idx(:combo) in states_to_enter
      refute idx(:combo) in default_entry
    end

    # AC: "default history content is invoked only for a state registered in
    # default_history_content"
    #
    # sabotage: `enter_history_target/3`'s recorded branch is changed to
    # also call `register_default_history_content/3` -> a *recorded* history
    # target would wrongly register default history content even though its
    # value was restored, reddening the refutation below.
    test "a recorded history registers no default history content" do
      m = machine()

      ms = %{
        machine_state(m)
        | history_values: %{idx(:combo_hist) => MapSet.new([idx(:combo_a)])}
      }

      to_combo_hist = transition_named(m, "go-combo-hist")

      {_states_to_enter, _default_entry, history_content} =
        ExitEntry.compute_entry_set(ms, [to_combo_hist])

      refute Map.has_key?(history_content, idx(:combo))
    end

    # AC: entry at two depths both run their own `onentry` - `arrive/3` calls
    # `run_onentry_blocks/2` unconditionally for *every* entered state, not
    # only leaves, so a compound (`deep`) and its child (`deep_child`) both
    # have their (distinct) blocks read on the same entry pass. This test
    # pins the precondition `run_onentry_blocks/2` needs for that per-state
    # read to mean anything: that `deep` and `deep_child` carry real,
    # distinct, non-empty onentry content in the compiled machine.
    #
    # sabotage: n/a - this test only checks that the fixture's onentry
    # blocks compiled at two distinct depths with distinct content; it does
    # not assert `exit_entry.ex` behavior on its own (the entry-order and
    # configuration-union tests above already exercise `arrive/3` /
    # `run_onentry_blocks/2` over this same document).
    test "onentry content exists at two different depths and is state-specific" do
      m = machine()

      deep_content = Machine.at(m, idx(:deep)).onentry |> Enum.flat_map(& &1.content)
      deep_child_content = Machine.at(m, idx(:deep_child)).onentry |> Enum.flat_map(& &1.content)

      assert deep_content != []
      assert deep_child_content != []
      refute deep_content == deep_child_content
    end
  end

  describe "completion events" do
    # AC: "done.state.{parent} on final entry into compound"
    #
    # sabotage: `raise_parent_completion/3`'s `MachineState.raise_platform/4`
    # call passes `{:state, parent}` instead of `{:state, state_index}` as
    # the cause origin -> `event.cause.origin` would name the parent
    # (`compound_final`) instead of the final state that actually entered
    # (`cf_done`), reddening the origin assertion below.
    test "entering a final inside a compound raises exactly one done.state.{parent_id}" do
      m = machine()
      ms = %{machine_state(m) | macrostep: 3, microstep: 2}
      transition = transition_named(m, "go-cf-done")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.compound_final"
      assert event.type == :platform
      assert event.data == nil
      assert event.cause.origin == {:state, idx(:cf_done)}
      assert event.cause.macrostep == 3
      assert event.cause.microstep == 2
    end

    # AC: "raised done.state.* events carry their static donedata"
    #
    # sabotage: `donedata/2`'s `{:static, text}` clause is changed to
    # return `{machine_state, text}` instead of coercing through
    # `EventData.coerce({:text, text})` -> the donedata would come back as
    # the string "42" instead of the coerced integer 42, reddening this
    # assertion.
    test "a final with static donedata carries it as the raised event's data" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-dd-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.donedata_holder"
      assert event.data == 42
    end

    # AC: "a <content expr> donedata evaluates and carries the value"
    #
    # sabotage: `evaluate_donedata/3`'s `{:ok, value}` clause is changed to
    # `EventData.coerce({:value, value + 1})` -> the evaluated `1 + 1`
    # would carry `3` instead of `2`, reddening this assertion.
    test "a compiled <content expr> donedata carries the evaluated value" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-ce-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.ce_holder"
      assert event.data == 2
    end

    # AC: "a failing <content expr> donedata yields nil data plus exactly
    # one error.execution, error enqueued before the done event"
    #
    # sabotage: `evaluate_donedata/3`'s `{:error, reason}` clause is
    # changed to skip the `MachineState.raise_platform/4` call and just
    # return `{machine_state, nil}` -> the `error.execution` event would
    # never be enqueued, reddening the two-event assertion below.
    test "a failing compiled <content expr> donedata yields nil data and one error.execution first" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-ce-fail-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [error_event, done_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert done_event.name == "done.state.ce_fail_holder"
      assert done_event.data == nil
    end

    # AC: "done.state.{grandparent} when a parallel completes"
    #
    # sabotage: `raise_parent_completion/3` is reordered to call
    # `maybe_raise_grandparent_completion/3` *before* raising the parent's
    # own `done.state.*` -> the internal queue would hold `done.state.par`
    # first and `done.state.reg2` second, reddening the ordered-match
    # assertion below.
    test "completing the second region of a parallel raises done.state.{grandparent} after the parent's" do
      m = machine()
      ms = machine_state(m, [idx(:region), idx(:par), idx(:reg1), idx(:reg1_final)])
      transition = transition_named(m, "go-reg2-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [reg_event, par_event] = MachineState.internal_events(result)
      assert reg_event.name == "done.state.reg2"
      assert reg_event.data == nil
      assert par_event.name == "done.state.par"
      assert par_event.data == nil
    end

    # sabotage: `maybe_raise_grandparent_completion/3`'s `Enum.all?/2` call
    # is changed to `Enum.any?/2` -> `done.state.par` would wrongly be
    # raised after only `reg1` completes (`reg2` still defaults to
    # `reg2_active`, not `reg2_final`), reddening the exact-match assertion
    # below.
    test "completing only the first region of a parallel raises only the parent's done.state" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-reg1-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.reg1"
    end

    # AC: "top-level final only clears running (no event) - matching the
    # pseudocode split"
    #
    # sabotage: `raise_completion_events/2`'s `parent == 0` check is
    # inverted to `parent != 0` -> the top-level branch (`running: false`)
    # is skipped in favor of `raise_parent_completion/3`, which raises
    # nothing here too (the `:scxml` root's own id is `nil`, so the
    # id-less-parent guard swallows it) - but `running` is left `true`,
    # reddening this assertion.
    test "entering a top-level final sets running: false and raises nothing" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-top-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert result.running == false
      assert MachineState.internal_events(result) == []
    end

    # AC: "a done.state.* whose parent state has no written id is not
    # raised"
    #
    # sabotage: `raise_parent_completion/3`'s guard is changed from
    # `is_binary(parent_id) and parent_id != ""` to `parent_id != ""`
    # (accepting `nil`) -> `"done.state." <> nil` raises an `ArgumentError`
    # instead of the crash-free no-op this test expects, reddening it.
    test "a compound parent with no id raises nothing and does not crash" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-noid-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert MachineState.internal_events(result) == []
      assert MapSet.member?(result.configuration, idx(:noid_final))
    end

    # AC: "a done.state.* whose *grandparent* state has no written id is not
    # raised" - the grandparent-side twin of the test above, exercising
    # `maybe_raise_grandparent_completion/3`'s own `_no_id` arm rather than
    # `raise_parent_completion/3`'s. `noid_par_reg2` itself has an id, so its
    # own `done.state.noid_par_reg2` still raises; only the parallel's event
    # is swallowed.
    #
    # sabotage: `maybe_raise_grandparent_completion/3`'s guard is changed
    # from `is_binary(grandparent_id) and grandparent_id != ""` to
    # `grandparent_id != ""` (accepting `nil`) -> `"done.state." <> nil`
    # raises an `ArgumentError` instead of the crash-free no-op this test
    # expects, reddening it.
    test "a parallel grandparent with no id raises nothing for itself and does not crash" do
      m = machine()

      ms =
        machine_state(m, [
          idx(:region),
          idx(:noid_par),
          idx(:noid_par_reg1),
          idx(:noid_par_reg1_final)
        ])

      transition = transition_named(m, "go-noid-par-reg2-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.noid_par_reg2"
      assert MapSet.member?(result.configuration, idx(:noid_par_reg2_final))
    end
  end

  describe "donedata <param>" do
    # A standalone document, compiled and machine-state-populated
    # independently of `@document`/`@indexes` above: `<param>` reading a
    # bound datamodel value needs `machine_state.datamodel` populated, which
    # none of the other tests in this file need, so this describe block
    # builds its own fixture and its own machine_state rather than growing
    # the shared indexed one.
    @param_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="trigger">
        <state id="trigger">
            <transition event="go-single" target="single_final"/>
            <transition event="go-multi" target="multi_final"/>
            <transition event="go-dup" target="dup_final"/>
            <transition event="go-loc" target="loc_final"/>
            <transition event="go-fail" target="fail_final"/>
            <transition event="go-only-fail" target="only_fail_final"/>
            <transition event="go-both-fail" target="both_fail_final"/>
        </state>
        <state id="single_holder">
            <final id="single_final">
                <donedata>
                    <param name="Var1" expr="Var1"/>
                </donedata>
            </final>
        </state>
        <state id="multi_holder">
            <final id="multi_final">
                <donedata>
                    <param name="Var1" expr="Var1"/>
                    <param name="Var2" expr="Var2"/>
                </donedata>
            </final>
        </state>
        <state id="dup_holder">
            <final id="dup_final">
                <donedata>
                    <param name="Var1" expr="Var1"/>
                    <param name="Var1" expr="Var2"/>
                </donedata>
            </final>
        </state>
        <state id="loc_holder">
            <final id="loc_final">
                <donedata>
                    <param name="Var1" location="Var1"/>
                </donedata>
            </final>
        </state>
        <state id="fail_holder">
            <final id="fail_final">
                <donedata>
                    <param name="Var1" expr="Var1"/>
                    <param name="Bad" expr="undeclared_var"/>
                </donedata>
            </final>
        </state>
        <state id="only_fail_holder">
            <final id="only_fail_final">
                <donedata>
                    <param name="Bad" expr="undeclared_var"/>
                </donedata>
            </final>
        </state>
        <!-- Two failing params sharing ONE expression: the case where the
             raised events' `data.source` strings are identical, so only the
             cause origin can say which `<param>` failed. -->
        <state id="both_fail_holder">
            <final id="both_fail_final">
                <donedata>
                    <param name="BadA" expr="undeclared_var"/>
                    <param name="BadB" expr="undeclared_var"/>
                </donedata>
            </final>
        </state>
    </scxml>
    """

    defp param_machine, do: compile!(@param_document)

    defp param_machine_state(machine) do
      %{machine_state(machine) | datamodel: %{"Var1" => 1, "Var2" => 2}}
    end

    # AC: "a single <param expr> produces event.data == %{"Var1" => 1}"
    #
    # sabotage: `evaluate_donedata_params/3`'s `{:ok, value}` clause is
    # changed to `{machine_state, pairs}` (dropping the pair) -> the params
    # arm would fold to `[]`, `EventData.coerce({:params, []})` returns
    # `nil` (Decision 5), reddening this assertion.
    test "a single <param expr> produces event.data == %{\"Var1\" => 1}" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-single")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.data == %{"Var1" => 1}
    end

    # AC: "multiple params merge in document order"
    #
    # sabotage: `evaluate_donedata_params/3`'s `Enum.reduce/3` call is
    # changed to fold over `Enum.take(params, 1)` instead of `params` ->
    # only the first `<param>` would survive, reddening this
    # two-key assertion (`event.data` comes back `%{"Var1" => 1}` instead
    # of `%{"Var1" => 1, "Var2" => 2}`).
    test "multiple params merge in document order" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-multi")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.data == %{"Var1" => 1, "Var2" => 2}
    end

    # AC: "a duplicate name takes the last value"
    #
    # `dup_final`'s `<param>` children are `name="Var1" expr="Var1"` (value
    # 1) then `name="Var1" expr="Var2"` (value 2) - document order.
    #
    # sabotage: `evaluate_donedata_params/3`'s final `Enum.reverse/1` call
    # is dropped -> the accumulated pairs stay in reverse-document order,
    # so `EventData.coerce/1`'s `Map.put/3` fold applies `Var1`'s own value
    # last instead of `Var2`'s, reddening this assertion (`%{"Var1" => 2}`
    # expected, `%{"Var1" => 1}` produced).
    test "a duplicate name takes the last value in document order" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-dup")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.data == %{"Var1" => 2}
    end

    # AC: "a <param location> over a bound datamodel path reads its value"
    #
    # sabotage: `Statifier.Compiler.build_donedata_param/2`'s
    # `param_location`-bearing clause is changed to compile the literal
    # string `"\"unbound\""` instead of `source` -> the param would read a
    # literal string instead of the bound `Var1`, reddening this assertion.
    test "a <param location> over a bound datamodel path reads its value" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-loc")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.data == %{"Var1" => 1}
    end

    # AC: "a failing param is omitted and produces one error.execution"
    #
    # sabotage: `evaluate_donedata_params/3`'s `{:error, reason}` clause is
    # changed to still add the pair with a `nil` value instead of dropping
    # it -> `event.data` would come back `%{"Var1" => 1, "Bad" => nil}`
    # instead of omitting `"Bad"` entirely, reddening the exact-match
    # assertion below.
    test "a failing param is omitted and produces exactly one error.execution" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-fail")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [error_event, done_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert done_event.data == %{"Var1" => 1}
    end

    # AC: "a <donedata> whose only param fails produces event.data == nil,
    # not %{}"
    #
    # sabotage: `Statifier.EventData.from_params/1`'s `[]` clause is
    # changed to `%{}` -> an all-failing param fold would carry `%{}` as
    # the done event's data instead of `nil`, reddening this assertion
    # (Decision 5).
    test "a donedata whose only param fails produces event.data == nil, not %{}" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-only-fail")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [error_event, done_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert done_event.data == nil
    end

    # AC: "a failing param's error names the param, not just its state"
    # (`docs/observability.md` constraint 4, ADR-0012 item 4).
    #
    # `fail_holder`'s failing `<param name="Bad">` is the SECOND child, so a
    # hardcoded `0` fails this just as a state-level origin does.
    #
    # sabotage: `evaluate_donedata_params/3`'s raise is reverted to the
    # `{:state, state_index}` origin it used before -> the assertion below
    # reddens with `{:state, 9}` against `{:donedata_param, 9, 1}`.
    test "a failing param's error.execution origin names the param, not the state" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-fail")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [error_event, _done_event] = MachineState.internal_events(result)
      assert {:donedata_param, state_index, 1} = error_event.cause.origin

      # The origin resolves to the `<param>` that actually failed.
      assert %Param{name: "Bad"} =
               m
               |> Machine.at(state_index)
               |> Map.fetch!(:donedata)
               |> Map.fetch!(:params)
               |> Enum.at(1)
    end

    # AC: same constraint, at the granularity that makes it load-bearing -
    # two failing params sharing one expression are indistinguishable by the
    # error payload's `source` string, so the origin is the only thing that
    # separates them.
    #
    # sabotage: `evaluate_donedata_params/3`'s `Enum.with_index/1` is dropped
    # and the origin's index hardcoded to `0` -> both origins come back
    # `{:donedata_param, _, 0}` and the distinctness assertion reddens, while
    # the `source`-equality assertion above it still passes, which is the
    # whole point.
    test "two failing params sharing one expression get distinct origins" do
      m = param_machine()
      ms = param_machine_state(m)
      transition = transition_named(m, "go-both-fail")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [first, second, done_event] = MachineState.internal_events(result)
      assert first.name == "error.execution"
      assert second.name == "error.execution"
      assert done_event.data == nil

      # The payloads alone cannot tell these two apart ...
      assert first.data.source == second.data.source

      # ... so the origin has to, in document order.
      assert {:donedata_param, state_index, 0} = first.cause.origin
      assert {:donedata_param, ^state_index, 1} = second.cause.origin

      params = m |> Machine.at(state_index) |> Map.fetch!(:donedata) |> Map.fetch!(:params)
      assert %Param{name: "BadA"} = Enum.at(params, 0)
      assert %Param{name: "BadB"} = Enum.at(params, 1)
    end
  end

  describe "in_final_state?/2" do
    # sabotage: `in_final_state?/2`'s compound branch's `Machine.final?/2`
    # check is dropped (any active child counts, final or not) ->
    # `cf_active` (active, not final) would wrongly make `compound_final`
    # answer `true`, reddening the sibling refutation test below.
    test "a compound with an active final child is true" do
      m = machine()
      ms = machine_state(m, [idx(:compound_final), idx(:cf_done)])

      assert ExitEntry.in_final_state?(ms, idx(:compound_final))
    end

    test "the same compound with a non-final active child is false" do
      m = machine()
      ms = machine_state(m, [idx(:compound_final), idx(:cf_active)])

      refute ExitEntry.in_final_state?(ms, idx(:compound_final))
    end

    # sabotage: `in_final_state?/2`'s parallel branch's `Enum.all?/2` is
    # changed to `Enum.any?/2` -> a parallel with only one of its two
    # regions final would wrongly answer `true`, reddening this refutation.
    test "a parallel is true only when every region is in a final state" do
      m = machine()
      partial = machine_state(m, [idx(:par), idx(:reg1), idx(:reg1_final), idx(:reg2)])
      refute ExitEntry.in_final_state?(partial, idx(:par))

      full =
        machine_state(m, [
          idx(:par),
          idx(:reg1),
          idx(:reg1_final),
          idx(:reg2),
          idx(:reg2_final)
        ])

      assert ExitEntry.in_final_state?(full, idx(:par))
    end

    # sabotage: `in_final_state?/2`'s `true -> false` fallback clause is
    # changed to `true -> Machine.final?(machine, state_index)` -> an atomic
    # final would wrongly answer `true` instead of `false`, reddening this
    # refutation.
    test "an atomic final is false" do
      m = machine()
      ms = machine_state(m, [idx(:reg1), idx(:reg1_final)])

      refute ExitEntry.in_final_state?(ms, idx(:reg1_final))
    end
  end

  # Proves the content seam is live end-to-end: entering a state with an
  # onentry <raise> now genuinely enqueues the event on the internal queue,
  # not the no-op stub's silent nothing. A dedicated document is used - the
  # shared `@document` above has no bare onentry <raise>.
  #
  # sabotage: `execute_block/3` in exit_entry.ex is reverted to the no-op
  # stub (`defp execute_block(machine_state, _owner, _c_indexes), do:
  # {machine_state, []}`) -> the internal queue stays empty, reddening this
  # assertion.
  test "the onentry seam is live: entering a with an onentry <raise> queues its event" do
    m =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="trigger">
          <state id="trigger">
              <transition event="go" target="a"/>
          </state>
          <state id="a">
              <onentry>
                  <raise event="in"/>
              </onentry>
          </state>
      </scxml>
      """)

    transition = transition_named(m, "go")
    ms = MachineState.new(m)

    {result, _effects} = ExitEntry.enter_states(ms, [transition])

    assert [%{name: "in", type: :internal}] = MachineState.internal_events(result)
  end

  describe "arrive/3's late-binding step (Phase 5)" do
    defp compile_late!(xml), do: compile!(xml)

    # A compound state `c` with its own state-scoped late-bound `<data>`,
    # entered directly (`go`), left (`leave`), and re-entered both by a
    # plain transition (`back_plain`) and through a shallow history (`back`)
    # - the two re-entry paths Phase 5's plan explicitly distinguishes
    # (`states_for_default_entry` would get the history path wrong).
    @late_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="outside" binding="late">
        <state id="outside">
            <transition event="go" target="c"/>
            <transition event="back" target="h"/>
            <transition event="back_plain" target="c"/>
        </state>
        <state id="c">
            <datamodel>
                <data id="X" expr="1"/>
            </datamodel>
            <initial>
                <transition target="c_a"/>
            </initial>
            <state id="c_a">
                <transition event="leave" target="outside"/>
            </state>
            <history id="h" type="shallow">
                <transition target="c_a"/>
            </history>
        </state>
    </scxml>
    """

    defp late_machine, do: compile_late!(@late_document)

    # sabotage: `Datamodel.bind_state_data/4`'s `:late` clause is changed to
    # read `Machine.at(machine, 0).data` (the root's own data, always empty
    # here) instead of `Machine.at(machine, state_index).data` -> `c`'s own
    # `<data id="X">` would never bind at first entry, reddening the `== 1`
    # assertion below.
    test "a state-scoped <data expr=\"1\"> is nil before first entry and 1 after" do
      m = late_machine()
      {:ok, c} = Machine.index(m, "c")

      {ms, _effects} = Interpreter.initialize(m)
      assert ms.datamodel["X"] == nil

      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("go"))

      assert MapSet.member?(ms.configuration, c)
      assert ms.datamodel["X"] == 1
    end

    # AC: "a re-entered state does not rebind" - the mutation the plan calls
    # out as "the one worth the most": `arrive/3` testing
    # `entered_states` membership *after* the `MapSet.put` instead of
    # before would make every entry, first or not, read as a first entry's
    # successor... no - it would make every entry look like a *repeat*, so
    # even the very first entry would never bind. That is caught by the
    # test above already; this test instead pins the complementary half -
    # a *second* entry must not rebind over a value a prior write left.
    #
    # sabotage: `arrive/3` puts `state_index` into `entered_states` *before*
    # testing membership (`first_entry? = not MapSet.member?(...)` moved to
    # after the `%{machine_state | entered_states: ...}` rebind) -> every
    # entry, including this test's plain re-entry, would test membership
    # against a set that already contains its own index, so `first_entry?`
    # is always false and `Datamodel.enter_state/2` is never called at all -
    # `X` would never leave its seeded `nil` even on the very first entry,
    # reddening the setup assertion `ms.datamodel["X"] == 1` before this
    # test's own re-entry check even runs.
    test "a state re-entered through a plain transition does not rebind" do
      m = late_machine()

      {ms, _effects} = Interpreter.initialize(m)
      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("go"))
      assert ms.datamodel["X"] == 1

      # Simulate an <assign>-equivalent write st-af3.4 will make real.
      ms = %{ms | datamodel: Map.put(ms.datamodel, "X", 99)}

      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("leave"))
      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("back_plain"))

      assert ms.datamodel["X"] == 99
    end

    # AC: "a state re-entered through history restoration does not rebind
    # either" - the case `states_for_default_entry` would get wrong: `c` is
    # re-entered here as the shallow history's parent, not via its own
    # `<initial>`, so it is never flagged in `states_for_default_entry` even
    # though it genuinely re-enters and `arrive/3` genuinely runs for it.
    #
    # sabotage: same as the plain-re-entry test above - `arrive/3` tests
    # `entered_states` membership after the `MapSet.put` rather than before.
    test "a state re-entered through history restoration does not rebind" do
      m = late_machine()

      {ms, _effects} = Interpreter.initialize(m)
      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("go"))
      assert ms.datamodel["X"] == 1

      ms = %{ms | datamodel: Map.put(ms.datamodel, "X", 99)}

      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("leave"))
      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("back"))

      {:ok, c_a} = Machine.index(m, "c_a")
      assert MapSet.member?(ms.configuration, c_a)
      assert ms.datamodel["X"] == 99
    end

    # sabotage: `arrive/3`'s `%{machine_state | entered_states:
    # MapSet.put(...)}` rebind is deleted, so `machine_state.entered_states`
    # never gains any member on entry -> `c`'s index would never join the
    # set, reddening the `MapSet.member?(ms.entered_states, c)` assertion
    # below before the round trip is even taken.
    test "entered_states survives a term_to_binary/1 round trip" do
      m = late_machine()
      {ms, _effects} = Interpreter.initialize(m)
      {:ok, ms, _effects} = Interpreter.handle_event(ms, Event.external("go"))

      {:ok, c} = Machine.index(m, "c")
      assert MapSet.member?(ms.entered_states, c)

      roundtripped = ms |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert roundtripped.entered_states == ms.entered_states
      assert MapSet.member?(roundtripped.entered_states, c)
    end
  end
end
