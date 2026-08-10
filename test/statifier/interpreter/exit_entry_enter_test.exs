defmodule Statifier.Interpreter.ExitEntryEnterTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Interpreter.ExitEntry
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
  # 20     (unnamed compound - no id)
  # 21       noid_final         (final)
  # 22     trigger             (go-* transitions)
  # 23   top_final              (final; parent 0 - top-level)
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
    trigger: 22,
    top_final: 23
  }

  defp machine, do: compile!(@document)
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
    # no-op stub (plan Decision 6), so no test here can observe a block
    # actually *running*; what is decidable without execution is that
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
    # sabotage: `static_donedata/2`'s `{:static, term}` clause is changed to
    # return `nil` instead of `term` -> the donedata's actual text ("42")
    # would be lost, reddening this assertion.
    test "a final with static donedata carries it as the raised event's data" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-dd-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.donedata_holder"
      assert event.data == "42"
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
    # nothing here too (the `:scxml` root's own id is `nil`, so Decision 9's
    # guard swallows it) - but `running` is left `true`, reddening this
    # assertion.
    test "entering a top-level final sets running: false and raises nothing" do
      m = machine()
      ms = machine_state(m)
      transition = transition_named(m, "go-top-final")

      {result, _effects} = ExitEntry.enter_states(ms, [transition])

      assert result.running == false
      assert MachineState.internal_events(result) == []
    end

    # AC: "a done.state.* whose parent state has no written id is not
    # raised" (Decision 9)
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
end
