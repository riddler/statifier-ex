defmodule Statifier.Interpreter.InvokeCallerContextTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering, Parser, Validator}

  # ADR-0063's 2026-09-01 amendment: the invoke seam joins the
  # carriers. `%Effect.Invoke{}` and `%Effect.CancelInvoke{}` are stamped
  # from `%MachineState{}.caller_context` at the same two construction
  # sites the counters are read at - `Interpreter.invoke_one/6` and
  # `Interpreter.ExitEntry.cancel_one_invocation/4` - so an asynchronous
  # handler has a scheduling-side term to store and put back on the
  # result event. The macrostep-level writers themselves are pinned in
  # `caller_context_test.exs`; this file pins the two invoke copies and
  # the deliberate `%Effect.Autoforward{}` non-copy.
  #
  # `s0` invokes at initialization (no caller); `s1` invokes on entry from
  # an event macrostep and autoforwards; `s2` exists so leaving `s1`
  # cancels its invocation inside a second, differently-stamped macrostep.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke id="inv-init" type="scxml"/>
          <transition event="go" target="s1"/>
      </state>
      <state id="s1">
          <invoke id="inv-live" type="scxml" autoforward="true"/>
          <transition event="next" target="s2"/>
      </state>
      <state id="s2"/>
  </scxml>
  """

  @host_context %{trace_id: "abc", span_id: 123}
  @other_context %{trace_id: "def", span_id: 456}

  defp compile! do
    {:ok, root} = Parser.parse(@document)
    {:ok, document} = Lowering.lower(root, @document)
    {:ok, document, _warnings} = Validator.validate(document, @document)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp invoke_effects(effects),
    do: for({:invoke, %Effect.Invoke{} = e} <- effects, do: e)

  defp cancel_invoke_effects(effects),
    do: for({:cancel_invoke, %Effect.CancelInvoke{} = e} <- effects, do: e)

  defp autoforward_effects(effects),
    do: for({:autoforward, %Effect.Autoforward{} = e} <- effects, do: e)

  # sabotage: `invoke_one/6`'s `caller_context: machine_state.caller_context`
  # line is deleted from the `%Effect.Invoke{}` literal -> the field falls
  # back to its `nil` default and the `@host_context` assertion reddens.
  # The initialization assertion stays green either way, which is what
  # makes it worth pairing with the event one.
  test "an invoke started in an event macrostep carries that event's context" do
    {machine_state, init_effects} = Interpreter.initialize(compile!())

    assert [%Effect.Invoke{invoke_id: "inv-init", caller_context: nil}] =
             invoke_effects(init_effects)

    assert {:ok, _machine_state, effects} =
             Interpreter.handle_event(
               machine_state,
               Event.external("go", caller_context: @host_context)
             )

    assert [%Effect.Invoke{invoke_id: "inv-live", caller_context: @host_context}] =
             invoke_effects(effects)
  end

  # sabotage: `ExitEntry.cancel_one_invocation/4`'s
  # `caller_context: machine_state.caller_context` line is deleted from the
  # `%CancelInvoke{}` literal -> the cancel carries `nil` and the
  # `@other_context` assertion reddens.
  #
  # The two macrosteps carry different contexts on purpose: the cancel is
  # stamped by the macrostep that *cancels*, not the one that started the
  # invocation, which is the same rule `%Cancel{}` follows for a delayed
  # send it cancels.
  test "a cancel_invoke carries the cancelling macrostep's context, not the starting one" do
    {machine_state, _init} = Interpreter.initialize(compile!())

    assert {:ok, machine_state, _effects} =
             Interpreter.handle_event(
               machine_state,
               Event.external("go", caller_context: @host_context)
             )

    assert {:ok, _machine_state, effects} =
             Interpreter.handle_event(
               machine_state,
               Event.external("next", caller_context: @other_context)
             )

    assert [%Effect.CancelInvoke{invoke_id: "inv-live", caller_context: @other_context}] =
             cancel_invoke_effects(effects)
  end

  # sabotage: a `caller_context` field is added to
  # `Statifier.Effect.Autoforward`'s defstruct -> the `has_key?` refutation
  # reddens. The amendment's point 2 is a deliberate non-change: the
  # forwarded `%Statifier.Event{}` travels whole, so its own slot already
  # carries the context and a field on the effect would be a second copy.
  test "an autoforward gains no field of its own; its event carries the slot" do
    {machine_state, _init} = Interpreter.initialize(compile!())

    assert {:ok, machine_state, _effects} =
             Interpreter.handle_event(machine_state, Event.external("go"))

    assert {:ok, _machine_state, effects} =
             Interpreter.handle_event(
               machine_state,
               Event.external("unhandled", caller_context: @host_context)
             )

    assert [%Effect.Autoforward{} = autoforward] = autoforward_effects(effects)
    refute Map.has_key?(autoforward, :caller_context)
    assert autoforward.event.caller_context == @host_context
  end
end
