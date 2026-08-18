defmodule Statifier.Interpreter.FinalizeTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Event, Interpreter, Lowering, Parser, Validator}
  alias Statifier.Effect.{Autoforward, DatamodelChange}
  alias Statifier.Effect.Trace.FinalizeAutoforward

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp autoforward_effects(effects) do
    for {:autoforward, %Autoforward{} = payload} <- effects, do: payload
  end

  defp datamodel_change_effects(effects) do
    for {:datamodel_change, %DatamodelChange{} = payload} <- effects, do: payload
  end

  defp finalize_autoforward_traces(effects) do
    for {:trace, %FinalizeAutoforward{} = payload} <- effects, do: payload
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-a", finalize assigns a_ran; invoke id="inv-b", finalize assigns b_ran)
  @two_invocations_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="a_ran" expr="false"/>
          <data id="b_ran" expr="false"/>
      </datamodel>
      <state id="s0">
          <invoke id="inv-a" type="scxml">
              <finalize>
                  <assign location="a_ran" expr="true"/>
              </finalize>
          </invoke>
          <invoke id="inv-b" type="scxml">
              <finalize>
                  <assign location="b_ran" expr="true"/>
              </finalize>
          </invoke>
      </state>
  </scxml>
  """

  # sabotage: `apply_invoke_passes_for_invocation/5`'s `invoke_id ==
  # event.invokeid` test is replaced with `true`, so every live invocation's
  # finalize runs regardless of the external event's invokeid -> `b_ran`
  # (which the matching-only assertion below expects to stay `false`)
  # becomes `true` too, reddening it. Confirmed red and reverted.
  test "only the matching invocation's finalize runs, and no other's (test234's rule)" do
    m = compile!(@two_invocations_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    assert {:ok, result, _effects} =
             Interpreter.handle_event(ms, Event.external("go", invokeid: "inv-a"))

    assert result.datamodel["a_ran"] == true
    assert result.datamodel["b_ran"] == false
  end

  # sabotage: `apply_invoke_passes/2`'s `finalized = invocations |>
  # Map.values() |> Enum.filter(&(&1 == event.invokeid)) |> Enum.uniq()`
  # line is changed to always produce `[]` -> `inv-a` disappears from
  # `trace.finalized` even though its finalize ran, reddening the
  # equality assertion below. Confirmed red and reverted.
  test "the finalize/autoforward pass emits Trace.FinalizeAutoforward naming the matched invocation" do
    m = compile!(@two_invocations_document)
    {ms, _init_effects} = Interpreter.initialize(m, trace: true)

    event = Event.external("go", invokeid: "inv-a")
    assert {:ok, _result, effects} = Interpreter.handle_event(ms, event)

    assert [trace] = finalize_autoforward_traces(effects)
    assert trace.event == event
    assert trace.finalized == ["inv-a"]
    assert trace.forwarded == []
  end

  #  0 scxml (root)
  #  1   s0      (no <invoke> at all; transition event="go" -> s1)
  #  2   s1
  @no_invocations_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <transition event="go" target="s1"/>
      </state>
      <state id="s1"/>
  </scxml>
  """

  # sabotage: `apply_invoke_passes/2`'s short-circuited
  # `map_size(invocations) == 0` clause is changed from building and
  # returning `trace` to `{machine_state, []}` -> no `Trace.FinalizeAutoforward`
  # is emitted at all, reddening the length-one assertion below. Confirmed
  # red and reverted.
  test "the finalize/autoforward pass emits Trace.FinalizeAutoforward with empty lists when there are no active invocations" do
    m = compile!(@no_invocations_document)
    {ms, _init_effects} = Interpreter.initialize(m, trace: true)

    event = Event.external("go")
    assert {:ok, _result, effects} = Interpreter.handle_event(ms, event)

    assert [trace] = finalize_autoforward_traces(effects)
    assert trace.event == event
    assert trace.finalized == []
    assert trace.forwarded == []
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-a" autoforward="true", finalize assigns a_ran)
  @autoforwarding_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="a_ran" expr="false"/>
      </datamodel>
      <state id="s0">
          <invoke id="inv-a" type="scxml" autoforward="true">
              <finalize>
                  <assign location="a_ran" expr="true"/>
              </finalize>
          </invoke>
      </state>
  </scxml>
  """

  # sabotage: `autoforward_effect/5`'s `%MInvoke{autoforward: true}` clause
  # is deleted, leaving only the `false` clause (which now matches
  # everything via the removed guard) -> no `Effect.Autoforward` is ever
  # produced, reddening the `assert [_autoforward]` match below. Confirmed
  # red and reverted.
  test "a matching and autoforwarding invocation produces both the datamodel write and Effect.Autoforward" do
    m = compile!(@autoforwarding_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    event = Event.external("go", invokeid: "inv-a")
    assert {:ok, result, effects} = Interpreter.handle_event(ms, event)

    assert result.datamodel["a_ran"] == true

    assert [autoforward] = autoforward_effects(effects)
    assert autoforward.invoke_id == "inv-a"
    assert autoforward.event == event
  end

  # `apply_invoke_passes/2` runs immediately after `handle_event/2`'s own
  # `MachineState.begin_macrostep/1` call and before any
  # `MachineState.begin_round/1` call, so `machine_state.round` is always 0
  # at the moment `autoforward_effect/5` stamps it - the pass's own position
  # ahead of the round-counted fold, not a coincidence of this fixture.
  #
  # sabotage: `autoforward_effect/5`'s `%Effect.Autoforward{}` literal is
  # changed from `round: machine_state.round` to a hardcoded `round: 7` ->
  # reddens against the real (always-0) value at this call site. Confirmed
  # red and reverted.
  test "the autoforward effect's round matches the machine state's round it was stamped from" do
    m = compile!(@autoforwarding_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    event = Event.external("go", invokeid: "inv-a")
    assert {:ok, _result, effects} = Interpreter.handle_event(ms, event)

    assert [autoforward] = autoforward_effects(effects)
    assert autoforward.round == 0
  end

  # sabotage: `apply_invoke_passes/2`'s `forwarded = for {:autoforward,
  # %Effect.Autoforward{invoke_id: id}} <- effects, do: id` line is changed
  # to always produce `[]` -> `inv-a` disappears from `trace.forwarded`
  # even though `Effect.Autoforward` names it, reddening the equality
  # assertion below. Confirmed red and reverted.
  test "a matching and autoforwarding invocation names inv-a in both Trace.FinalizeAutoforward lists" do
    m = compile!(@autoforwarding_document)
    {ms, _init_effects} = Interpreter.initialize(m, trace: true)

    event = Event.external("go", invokeid: "inv-a")
    assert {:ok, _result, effects} = Interpreter.handle_event(ms, event)

    assert [trace] = finalize_autoforward_traces(effects)
    assert trace.finalized == ["inv-a"]
    assert trace.forwarded == ["inv-a"]
  end

  # sabotage: `autoforward_effect/5`'s `%MInvoke{autoforward: true}` clause
  # is deleted, leaving only the `false` clause (which now matches
  # everything via the removed guard) -> no `Effect.Autoforward` is ever
  # produced, even though `inv-a` autoforwards, reddening the assertion
  # below. Confirmed red and reverted.
  test "an event with no invokeid triggers no finalize but still autoforwards" do
    m = compile!(@autoforwarding_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    assert {:ok, result, effects} = Interpreter.handle_event(ms, Event.external("go"))

    assert result.datamodel["a_ran"] == false
    assert [autoforward] = autoforward_effects(effects)
    assert autoforward.invoke_id == "inv-a"
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-empty" namelist="var_empty"; empty <finalize/>)
  #  1   s0      (invoke id="inv-absent" namelist="var_absent"; no <finalize> child)
  @namelist_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="var_empty"/>
          <data id="var_absent"/>
      </datamodel>
      <state id="s0">
          <invoke id="inv-empty" type="scxml" namelist="var_empty">
              <finalize/>
          </invoke>
          <invoke id="inv-absent" type="scxml" namelist="var_absent"/>
      </state>
  </scxml>
  """

  # sabotage: `apply_finalize/5`'s `%MInvoke{finalize: %Block{content: []}}`
  # clause (the empty case) is deleted, leaving only the `nil` (absent, a
  # no-op) and populated-block clauses -> an empty `<finalize>` now falls
  # through to the populated-block clause, which calls
  # `Content.execute_block/3` over an empty `c_indexes` list rather than
  # auto-assigning `var_empty`, reddening the assertion below. Confirmed red
  # and reverted.
  test "an empty <finalize> auto-assigns matching namelist names; an absent one does not" do
    m = compile!(@namelist_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    assert {:ok, empty_result, _effects} =
             Interpreter.handle_event(
               ms,
               %Event{
                 name: "go",
                 type: :external,
                 invokeid: "inv-empty",
                 data: %{"var_empty" => 42}
               }
             )

    assert empty_result.datamodel["var_empty"] == 42

    assert {:ok, absent_result, _effects} =
             Interpreter.handle_event(
               ms,
               %Event{
                 name: "go",
                 type: :external,
                 invokeid: "inv-absent",
                 data: %{"var_absent" => 99}
               }
             )

    assert absent_result.datamodel["var_absent"] == nil
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-param"; <param name="p" location="param_target"/>; empty <finalize/>;
  #               transition event="go" -> s1)
  #  2   s1
  @param_location_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="param_target"/>
      </datamodel>
      <state id="s0">
          <invoke id="inv-param" type="scxml">
              <param name="p" location="param_target"/>
              <finalize/>
          </invoke>
      </state>
  </scxml>
  """

  # sabotage: `write_finalize_target/6`'s `Datamodel.write_location/4` call
  # is replaced with `{:ok, machine_state, context}` unconditionally,
  # dropping the write -> `param_target` stays `nil`, reddening the
  # assertion below. Confirmed red and reverted.
  test "an empty <finalize> auto-assigns a matching <param location> target" do
    m = compile!(@param_location_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    assert {:ok, result, _effects} =
             Interpreter.handle_event(
               ms,
               %Event{name: "go", type: :external, invokeid: "inv-param", data: %{"p" => "hi"}}
             )

    assert result.datamodel["param_target"] == "hi"
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-a", finalize assigns flag=true; transition event="go" cond="flag" -> s1)
  #  2   s1
  @finalize_before_selection_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="flag" expr="false"/>
      </datamodel>
      <state id="s0">
          <invoke id="inv-a" type="scxml">
              <finalize>
                  <assign location="flag" expr="true"/>
              </finalize>
          </invoke>
          <transition event="go" cond="flag" target="s1"/>
      </state>
      <state id="s1"/>
  </scxml>
  """

  # sabotage: `handle_event/2`'s `apply_invoke_passes/2` call is moved to
  # after `Selection.select_transitions/2` instead of before it -> the
  # `cond="flag"` transition is evaluated against the pre-finalize value
  # (`false`), so it is never selected and the configuration never reaches
  # `s1`, reddening the assertion below. Confirmed red and reverted.
  test "finalize runs before transition selection" do
    m = compile!(@finalize_before_selection_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    {:ok, s1_index} = Statifier.Machine.index(m, "s1")

    assert {:ok, result, _effects} =
             Interpreter.handle_event(ms, Event.external("go", invokeid: "inv-a"))

    assert MapSet.member?(result.configuration, s1_index)
  end

  #  0 scxml (root)
  #  1   s0      (transition event="go" cond="_event.invokeid == 'abc'" -> s1)
  #  2   s1
  @readable_invokeid_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <transition event="go" cond="_event.invokeid == 'abc'" target="s1"/>
      </state>
      <state id="s1"/>
  </scxml>
  """

  # sabotage: `Statifier.Evaluator.SystemVariables.event/1`'s `"invokeid" =>
  # event.invokeid` is replaced with `"invokeid" => nil` -> `_event.invokeid`
  # reads `undefined` instead of `"abc"`, so the `cond` never matches and the
  # configuration never reaches `s1`, reddening the assertion below.
  # Confirmed red and reverted.
  test "_event.invokeid is readable from a cond" do
    m = compile!(@readable_invokeid_document)
    {ms, _init_effects} = Interpreter.initialize(m)

    {:ok, s1_index} = Statifier.Machine.index(m, "s1")

    assert {:ok, result, _effects} =
             Interpreter.handle_event(ms, Event.external("go", invokeid: "abc"))

    assert MapSet.member?(result.configuration, s1_index)
  end

  describe "the empty-<finalize> auto-assign's :datamodel_change effect" do
    #  0 scxml (root)
    #  1   s0      (invoke id="inv-fail"; <param name="p" location="_sessionid"/>; empty <finalize/>)
    @failing_param_location_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke id="inv-fail" type="scxml">
                <param name="p" location="_sessionid"/>
                <finalize/>
            </invoke>
        </state>
    </scxml>
    """

    # sabotage: `write_finalize_target/6`'s success clause builds the
    # `{:datamodel_change, _}` effect unconditionally, even on the `{:error,
    # reason}` branch (folding both clauses into one) -> the system-variable
    # write failure below would still emit an effect, reddening this test's
    # empty-list assertion. Confirmed red and reverted.
    test "a failed auto-assign write emits no :datamodel_change effect" do
      m = compile!(@failing_param_location_document)
      {ms, _init_effects} = Interpreter.initialize(m)

      assert {:ok, _result, effects} =
               Interpreter.handle_event(
                 ms,
                 %Event{name: "go", type: :external, invokeid: "inv-fail", data: %{"p" => "hi"}}
               )

      assert datamodel_change_effects(effects) == []
    end

    # sabotage: `write_finalize_target/6`'s success clause hardcodes
    # `owner: {:finalize, 0, 0}` instead of `{:finalize, state_index,
    # invoke_index}` -> since `s0` is not index `0` (the root is), this
    # test's `owner` assertion reddens. Confirmed red and reverted.
    test "a successful auto-assign write emits a :datamodel_change naming the path, both values, and owner" do
      m = compile!(@param_location_document)
      {:ok, s0_index} = Statifier.Machine.index(m, "s0")
      {ms, _init_effects} = Interpreter.initialize(m)

      assert {:ok, result, effects} =
               Interpreter.handle_event(
                 ms,
                 %Event{name: "go", type: :external, invokeid: "inv-param", data: %{"p" => "hi"}}
               )

      assert [change] = datamodel_change_effects(effects)
      assert change.location_path == ["param_target"]
      assert change.location_source == "param_target"
      assert change.new_value == "hi"
      assert change.prior_value == nil
      assert change.c_index == nil
      assert change.owner == {:finalize, s0_index, 0}
      assert result.datamodel["param_target"] == "hi"
    end

    # `write_finalize_target/6` runs inside `apply_invoke_passes/2`, which
    # `handle_event/2` calls immediately after its own `begin_macrostep/1`
    # (which resets `round` to 0) and before any `begin_round/1` call -
    # exactly the position this file's "the autoforward effect's round
    # matches the machine state's round it was stamped from" test above
    # documents for `autoforward_effect/5`. `machine_state.round` is
    # therefore always 0 at this call site too, so this test asserts
    # `round: 0` deliberately, not as a weak literal - the sabotage below
    # still distinguishes "reads machine_state.round" from a hardcoded
    # wrong constant.
    #
    # sabotage: `write_finalize_target/6`'s `%Effect.DatamodelChange{}`
    # literal is changed from `round: machine_state.round` to a hardcoded
    # `round: 3` -> reddens against the real (always-0) value at this call
    # site. Confirmed red and reverted.
    test "the auto-assign's :datamodel_change effect's round matches the machine state's round it was stamped from" do
      m = compile!(@param_location_document)
      {ms, _init_effects} = Interpreter.initialize(m)

      assert {:ok, _result, effects} =
               Interpreter.handle_event(
                 ms,
                 %Event{name: "go", type: :external, invokeid: "inv-param", data: %{"p" => "hi"}}
               )

      assert [change] = datamodel_change_effects(effects)
      assert change.round == 0
    end
  end
end
