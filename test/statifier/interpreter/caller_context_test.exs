defmodule Statifier.Interpreter.CallerContextTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering}
  alias Statifier.{Parser, Validator}

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # ADR-0063 decision 3: `%MachineState{}.caller_context` is transient
  # per-macrostep fold state with exactly three writers -
  # `Interpreter.handle_event/2` (the triggering event's slot),
  # `initialize/2` and `cancel/1` (both `nil`) - and the two durable-timer
  # effect constructors copy it. This file pins the writers end-to-end;
  # the per-constructor copies are pinned in
  # `test/statifier/machine/content/send_test.exs` and `cancel_test.exs`.
  #
  # `a` schedules a delayed send during the *initialization* macrostep;
  # `b` schedules one and cancels `init_timer` during an *event* macrostep;
  # `c` exists so a second external event can overwrite the stamp.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry><send event="init_tick" delay="1s" id="init_timer"/></onentry>
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <onentry>
              <send event="tick" delay="1s" id="t1"/>
              <cancel sendid="init_timer"/>
          </onentry>
          <transition event="next" target="c"/>
      </state>
      <state id="c">
          <onentry><send event="late_tick" delay="1s" id="t2"/></onentry>
      </state>
  </scxml>
  """

  @host_context %{trace_id: "abc", span_id: 123}

  defp machine, do: compile!(@document)

  defp send_delayed_effects(effects),
    do: for({:send_delayed, %Effect.SendDelayed{} = e} <- effects, do: e)

  defp cancel_effects(effects),
    do: for({:cancel, %Effect.Cancel{} = e} <- effects, do: e)

  # sabotage: `Interpreter.initialize/2`'s explicit
  # `%{machine_state | caller_context: nil}` write is changed to stamp a
  # non-nil sentinel -> both assertions redden (the initialization
  # macrostep has no sending caller, so its stamp and its effects carry
  # `nil`).
  test "initialize/2 stamps nil and its delayed sends carry nil" do
    {machine_state, effects} = Interpreter.initialize(machine())

    assert machine_state.caller_context == nil
    assert [%Effect.SendDelayed{caller_context: nil}] = send_delayed_effects(effects)
  end

  # sabotage: `Interpreter.handle_event/2`'s
  # `%{machine_state | caller_context: event.caller_context}` write is
  # deleted -> every assertion below reddens: the fold keeps the
  # initialization macrostep's `nil` and both effects copy that instead.
  test "handle_event/2 stamps the triggering event's context onto fold and effects" do
    {machine_state, _init_effects} = Interpreter.initialize(machine())

    event = Event.external("go", caller_context: @host_context)
    assert {:ok, machine_state, effects} = Interpreter.handle_event(machine_state, event)

    assert machine_state.caller_context == @host_context
    assert [%Effect.SendDelayed{caller_context: @host_context}] = send_delayed_effects(effects)
    assert [%Effect.Cancel{caller_context: @host_context}] = cancel_effects(effects)
  end

  # sabotage: `handle_event/2`'s write is changed to keep a prior non-nil
  # value (`caller_context: machine_state.caller_context ||
  # event.caller_context`) -> the second macrostep below would inherit the
  # first one's context and both `nil` assertions redden. Every
  # macrostep-opening entry point overwrites the field, so it never holds
  # a stale value.
  test "an event without a context overwrites a prior macrostep's stamp" do
    {machine_state, _init} = Interpreter.initialize(machine())

    {:ok, machine_state, _effects} =
      Interpreter.handle_event(
        machine_state,
        Event.external("go", caller_context: @host_context)
      )

    assert {:ok, machine_state, effects} =
             Interpreter.handle_event(machine_state, Event.external("next"))

    assert machine_state.caller_context == nil
    assert [%Effect.SendDelayed{caller_context: nil}] = send_delayed_effects(effects)
  end

  # sabotage: `Interpreter.cancel/1`'s `caller_context: nil` write is
  # dropped from its struct update -> the assertion reddens: the fold
  # would still hold the previous event macrostep's context while
  # `exit_interpreter/1` runs.
  test "cancel/1 overwrites the stamp with nil" do
    {machine_state, _init} = Interpreter.initialize(machine())

    {:ok, machine_state, _effects} =
      Interpreter.handle_event(
        machine_state,
        Event.external("go", caller_context: @host_context)
      )

    assert {:ok, machine_state, _effects} = Interpreter.cancel(machine_state)
    assert machine_state.caller_context == nil
  end
end
