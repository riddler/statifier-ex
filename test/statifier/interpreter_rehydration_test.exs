defmodule Statifier.InterpreterRehydrationTest do
  use ExUnit.Case, async: true

  alias Statifier.{Effect, Event, Interpreter, Machine, MachineState, Position}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Send.Routes

  # A `Statifier.compile/2` chart (not the bare `Compiler.compile/1` most
  # interpreter tests use): `Position.to_binary/1` refuses a machine with no
  # identity, and this whole module is about the rehydration path that
  # identity gates.
  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp state_index(machine, id) do
    {:ok, index} = Machine.index(machine, id)
    index
  end

  # History (shallow, on "p"), a datamodel counter, and a generated <send>
  # on every entry into "a"/"b" - enough to make the persisted position's
  # history_values, datamodel, and send_counter all non-trivial.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <history id="h" type="shallow">
              <transition target="a"/>
          </history>
          <state id="a">
              <onentry>
                  <assign location="count" expr="count + 1"/>
                  <send event="entered_a"/>
              </onentry>
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
                  <send event="entered_b"/>
              </onentry>
              <transition event="leave" target="outside"/>
          </state>
      </state>
      <state id="outside">
          <transition event="back" target="h"/>
      </state>
  </scxml>
  """

  # Drives a fresh `machine` to a quiescent, non-trivial position: p/a ->
  # p/b (bumping `count` and minting two generated <send> ids) -> outside,
  # recording "b" in "h"'s shallow history. macrostep/microstep/round and
  # send_counter are all non-zero by the time this returns, and the internal
  # queue is empty (the identity-check-only precondition `Position.to_binary/1`
  # needs, not `:resume`'s own quiescence refusal - Phase 4's concern).
  defp positioned(machine) do
    {machine_state, _effects} = Interpreter.initialize(machine)
    {:ok, machine_state, _effects} = Interpreter.handle_event(machine_state, Event.external("go"))

    {:ok, machine_state, _effects} =
      Interpreter.handle_event(machine_state, Event.external("leave"))

    machine_state
  end

  # The rehydration path this phase documents: `Position.to_binary/1` off
  # `machine_state`, `from_binary/2` back against `target_machine` (a
  # separately compiled `%Machine{}` from the same source, simulating a
  # fresh host process), then re-stamp `routes` and `invoke_types` - the two
  # fields `from_binary/2` always comes back `nil`.
  defp rehydrate!(machine_state, target_machine) do
    assert {:ok, blob} = Position.to_binary(machine_state)
    assert {:ok, rehydrated} = Position.from_binary(blob, target_machine)
    assert rehydrated.routes == nil
    assert rehydrated.invoke_types == nil

    rehydrated
    |> MachineState.put_routes(Routes.new(sessions: ["sess_rehydrated"]))
    |> MachineState.put_invoke_types(InvokeTypes.new())
  end

  # sabotage: `Position.from_binary/2`'s success arm is changed from
  # `struct!(MachineState, Map.put(upgraded_payload, :machine, machine))` to
  # `MachineState.new(machine)` (rebuild fresh instead of restoring the
  # decoded payload) -> the rehydrated position's `history_values` comes
  # back `%{}` instead of carrying "h" -> "b", so `handle_event/2` on
  # "back" re-enters "a" (the history's own default target) instead of "b",
  # reddening the configuration equality below. Reverted and confirmed
  # green.
  test "handle_event/2 produces the same configuration and effects on a rehydrated position as on the un-round-tripped one" do
    machine_a = compile!(@document)
    machine_b = compile!(@document)

    original = positioned(machine_a)
    rehydrated = rehydrate!(positioned(machine_b), machine_b)

    assert {:ok, original_result, original_effects} =
             Interpreter.handle_event(original, Event.external("back"))

    assert {:ok, rehydrated_result, rehydrated_effects} =
             Interpreter.handle_event(rehydrated, Event.external("back"))

    assert original_result.configuration == rehydrated_result.configuration
    assert original_effects == rehydrated_effects

    # Both land on "b" - the shallow history's persisted member, not "a"
    # (the history's own default target).
    assert MapSet.member?(original_result.configuration, state_index(machine_a, "b"))
    assert MapSet.member?(rehydrated_result.configuration, state_index(machine_b, "b"))
  end

  # sabotage: `Statifier.Machine.Content.Send`'s `generate_send_id/2`
  # (`lib/statifier/machine/content/send.ex`) is changed from
  # `"send_" <> Integer.to_string(counter + 1)` to a hardcoded
  # `"send_" <> Integer.to_string(1)` -> the send minted for the rehydrated
  # position's history re-entry collides with the "send_1" already minted
  # before persist instead of continuing to "send_3", reddening the
  # `send_ids == ["send_3"]` assertion below. Reverted and confirmed green.
  test "deliver_internal/5 on a rehydrated position continues its counters and mints non-colliding send ids" do
    machine_a = compile!(@document)
    machine_b = compile!(@document)

    original = positioned(machine_a)
    assert original.send_counter == 2
    assert original.macrostep > 0

    rehydrated = rehydrate!(original, machine_b)
    assert rehydrated.send_counter == 2
    assert rehydrated.macrostep == original.macrostep

    assert {:ok, result, effects} =
             Interpreter.deliver_internal(rehydrated, :internal, "back", {:state, 0}, [])

    # `deliver_internal/5` re-enters within the same macrostep (ADR-0039) -
    # the counters continue from the persisted position rather than
    # restarting: `macrostep` stays at the persisted value, not reset to 1.
    assert result.macrostep == original.macrostep

    # Re-entering "b" via the restored history mints a *third* generated
    # send id, continuing the persisted send_counter rather than
    # restarting at "send_1"/"send_2" - both already minted before persist.
    send_ids =
      effects
      |> Enum.filter(&match?({:send, %Effect.Send{}}, &1))
      |> Enum.map(fn {:send, %Effect.Send{send_id: send_id}} -> send_id end)

    assert send_ids == ["send_3"]
    assert result.send_counter == 3
  end

  # sabotage: `Position.to_binary/1`'s payload is changed from
  # `Map.from_struct(machine_state) |> Map.delete(:machine)` to also
  # `Map.delete(:history_values)` -> `from_binary/2`'s `struct!/2` rebuild
  # falls back to the struct's own default (`%{}`) for the missing key, so
  # the rehydrated position's `history_values` comes back empty instead of
  # naming "h" -> "b", reddening both the equality assertion and the
  # restored-"b" assertion below. Reverted and confirmed green.
  test "history values survive the round trip and restore the persisted set, not the initial one" do
    machine_a = compile!(@document)
    machine_b = compile!(@document)

    original = positioned(machine_a)
    refute original.history_values == %{}

    rehydrated = rehydrate!(original, machine_b)
    assert rehydrated.history_values == original.history_values

    assert {:ok, result, _effects} =
             Interpreter.handle_event(rehydrated, Event.external("back"))

    # "h"'s default target is "a" - reaching "b" instead proves the
    # persisted history value won, not the document's own default.
    refute MapSet.member?(result.configuration, state_index(machine_b, "a"))
    assert MapSet.member?(result.configuration, state_index(machine_b, "b"))
  end
end
