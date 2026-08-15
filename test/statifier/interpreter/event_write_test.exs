defmodule Statifier.Interpreter.EventWriteTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order.
  #
  #  0 scxml (root; initial="s0")
  #  1   s0  -- onentry raises "e1"; transition event="e1" -> s1
  #  2   s1  -- transition event="go" -> s2 (external event)
  #  3   s2
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <onentry>
              <raise event="e1"/>
          </onentry>
          <transition event="e1" target="s1"/>
      </state>
      <state id="s1">
          <transition event="go" target="s2"/>
      </state>
      <state id="s2"/>
  </scxml>
  """

  defp machine, do: compile!(@document)

  # `datamodel["_event"] = internalEvent` (Appendix D): `initialize/2` runs
  # s0's onentry, which raises "e1" as an internal event; `internal_round/1`
  # dequeues it and writes it before selection, so it is already visible on
  # the position `initialize/2` returns (s1 is entered on the same fold).
  #
  # sabotage: `internal_round/1`'s `machine_state =
  # MachineState.put_event(machine_state, event)` call is deleted -> the
  # internal round's own `_event` write disappears, and `datamodel["_event"]`
  # is unset, reddening this assertion.
  test "internal_round/1 writes _event for the dequeued internal event" do
    {machine_state, _effects} = Interpreter.initialize(machine())

    assert machine_state.datamodel["_event"]["name"] == "e1"
    assert machine_state.datamodel["_event"]["type"] == "internal"
  end

  # `datamodel["_event"] = externalEvent` (Appendix D): a run whose content
  # raises an internal event (asserted above) then leaves it equal to the
  # *external* event's name once `handle_event/2`'s own write lands, tested
  # separately so a single seam wired correctly cannot mask a missing one.
  #
  # sabotage: `handle_event/2`'s `machine_state =
  # MachineState.put_event(machine_state, event)` call is deleted -> the
  # external event's own write disappears and `_event` still names the
  # internal round's "e1", reddening this assertion.
  test "handle_event/2 writes _event for the external event" do
    {machine_state, _effects} = Interpreter.initialize(machine())

    {:ok, machine_state, _effects} = Interpreter.handle_event(machine_state, Event.external("go"))

    assert machine_state.datamodel["_event"]["name"] == "go"
    assert machine_state.datamodel["_event"]["type"] == "external"
  end
end
