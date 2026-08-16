defmodule Statifier.Interpreter.FinalizeTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.Trace.FinalizeAutoforward
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator

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
          <invoke id="inv-a" type="t.a">
              <finalize>
                  <assign location="a_ran" expr="true"/>
              </finalize>
          </invoke>
          <invoke id="inv-b" type="t.b">
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
          <invoke id="inv-a" type="t.a" autoforward="true">
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
          <invoke id="inv-empty" type="t" namelist="var_empty">
              <finalize/>
          </invoke>
          <invoke id="inv-absent" type="t" namelist="var_absent"/>
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
          <invoke id="inv-param" type="t">
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
          <invoke id="inv-a" type="t">
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
end
