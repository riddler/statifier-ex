defmodule Statifier.Interpreter.CancelInvokeTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering, Machine, Parser, Validator}
  alias Statifier.Effect.CancelInvoke

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  defp invoke_effects(effects) do
    for {:invoke, %Effect.Invoke{} = payload} <- effects, do: payload
  end

  defp cancel_invoke_effects(effects) do
    for {:cancel_invoke, %CancelInvoke{} = payload} <- effects, do: payload
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-a"; invoke id="inv-b"; onexit logs; -> s1 on "go")
  #  2   s1
  @two_invocations_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke id="inv-a" type="t.a"/>
          <invoke id="inv-b" type="t.b"/>
          <onexit>
              <log label="s0-exit"/>
          </onexit>
          <transition event="go" target="s1"/>
      </state>
      <state id="s1"/>
  </scxml>
  """

  # sabotage: `ExitEntry.depart/2`'s final `{machine_state, onexit_effects ++
  # cancel_effects}` is changed to `cancel_effects ++ onexit_effects`,
  # reversing the two halves -> the `:log` effect (from `onexit`) now
  # follows both `:cancel_invoke` effects instead of preceding them,
  # reddening the ordering assertion below. Confirmed red and reverted.
  test "a transition out of an invoking state cancels each invocation after onexit, in document order" do
    m = compile!(@two_invocations_document)
    {ms, init_effects} = Interpreter.initialize(m)

    assert [inv_a, inv_b] = invoke_effects(init_effects)

    assert {:ok, result, effects} = Interpreter.handle_event(ms, Event.external("go"))

    onexit_index = Enum.find_index(effects, &match?({:log, _payload}, &1))
    first_cancel_index = Enum.find_index(effects, &match?({:cancel_invoke, _payload}, &1))

    assert is_integer(onexit_index)
    assert is_integer(first_cancel_index)
    assert onexit_index < first_cancel_index

    cancels = cancel_invoke_effects(effects)
    assert Enum.map(cancels, & &1.invoke_id) == [inv_a.invoke_id, inv_b.invoke_id]
    assert Enum.all?(cancels, &(&1.state_index == idx(m, "s0")))

    assert result.active_invocations == %{}
  end

  #  0 scxml (root)
  #  1   s0      (invoke id="inv-a"; no transition out)
  @live_invocation_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke id="inv-a" type="t.a"/>
      </state>
  </scxml>
  """

  # A transition into a top-level `<final>` cannot exercise
  # `exit_interpreter/1`'s own cancel walk in this engine: `getTransitionDomain`
  # (Appendix D) is always the root itself whenever a target is a direct
  # child of the root (its only ancestor is the root), so `exit_states/2`'s
  # ordinary walk already empties the whole configuration - and cancels
  # `inv-a` through `depart/2` - before `running` ever goes false. The
  # second caller `exit_interpreter/1`'s own `@doc` names,
  # `Interpreter.cancel/1` (spec 6.3's cancel operation), is the one real
  # path that reaches it with a still-live invocation: it sets `running:
  # false` directly with no exit walk at all, so every currently-invoking
  # state is still in the configuration when this function's own cancel
  # walk runs.
  #
  # sabotage: `Statifier.Interpreter.exit_interpreter/1`'s new
  # `ExitEntry.cancel_invocations_for_state/2` call is replaced with
  # `{ms, []}`, dropping the cancel walk -> no `:cancel_invoke` effect is
  # produced on termination, reddening the assertion below. Confirmed red
  # and reverted.
  test "Interpreter.cancel/1 cancels a live invocation from exit_interpreter/1's own walk" do
    m = compile!(@live_invocation_document)
    {ms, init_effects} = Interpreter.initialize(m)

    assert [inv_a] = invoke_effects(init_effects)

    assert {:ok, result, effects} = Interpreter.cancel(ms)

    assert [cancel] = cancel_invoke_effects(effects)
    assert cancel.invoke_id == inv_a.invoke_id
    assert cancel.state_index == idx(m, "s0")

    assert result.active_invocations == %{}
    refute result.running
  end

  # sabotage: `ExitEntry.cancel_one_invocation/4`'s `%CancelInvoke{}` literal
  # is changed from `round: machine_state.round` to `round: 0` -> reddens
  # against this fixture, whose `machine_state.round` is set to a nonzero
  # value before `Interpreter.cancel/1`'s exit walk runs. Confirmed red and
  # reverted.
  test "the cancel_invoke effect's round matches the machine state's round it was stamped from" do
    m = compile!(@live_invocation_document)
    {ms, _init_effects} = Interpreter.initialize(m)
    ms = %{ms | round: 4}

    assert {:ok, _result, effects} = Interpreter.cancel(ms)

    assert [cancel] = cancel_invoke_effects(effects)
    assert cancel.round == 4
  end

  #  0 scxml (root)
  #  1   s0      (invoke typeexpr="undefined_var" fails; -> s1 on "go")
  #  2   s1
  @failed_invocation_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke typeexpr="undefined_var"/>
          <transition event="go" target="s1"/>
      </state>
      <state id="s1"/>
  </scxml>
  """

  # sabotage: `ExitEntry.cancel_one_invocation/4`'s `:error` clause (leave
  # `ms`/`effects` untouched) is replaced with a clause that emits a cancel
  # unconditionally, using a placeholder `invoke_id` -> a `:cancel_invoke`
  # effect appears for the invocation that never started, reddening the
  # `refute` below. Confirmed red and reverted.
  test "an invocation whose arguments failed produces no cancel on exit" do
    m = compile!(@failed_invocation_document)
    {ms, init_effects} = Interpreter.initialize(m)

    assert invoke_effects(init_effects) == []

    assert {:ok, _result, effects} = Interpreter.handle_event(ms, Event.external("go"))

    refute Enum.any?(effects, &match?({:cancel_invoke, _}, &1))
  end

  #  0 scxml (root)
  #  1   s0      (invoke type="t"; -> s1 on "leave")
  #  2   s1      (-> s0 on "back")
  @reentry_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke type="t"/>
          <transition event="leave" target="s1"/>
      </state>
      <state id="s1">
          <transition event="back" target="s0"/>
      </state>
  </scxml>
  """

  # sabotage: `invoke_one/6`'s generated-id clauses are both replaced with a
  # single hardcoded string, `"fixed_id"` -> the second entry's invoke_id
  # equals the first's, reddening the inequality assertion below. Confirmed
  # red and reverted.
  test "re-entering a state produces a new invokeid on the next invoke pass" do
    m = compile!(@reentry_document)
    {ms, init_effects} = Interpreter.initialize(m)

    assert [first_invoke] = invoke_effects(init_effects)

    assert {:ok, ms, leave_effects} = Interpreter.handle_event(ms, Event.external("leave"))
    assert [cancel] = cancel_invoke_effects(leave_effects)
    assert cancel.invoke_id == first_invoke.invoke_id

    assert {:ok, _result, back_effects} = Interpreter.handle_event(ms, Event.external("back"))
    assert [second_invoke] = invoke_effects(back_effects)

    refute second_invoke.invoke_id == first_invoke.invoke_id
  end
end
