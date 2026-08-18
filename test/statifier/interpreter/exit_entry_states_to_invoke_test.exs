defmodule Statifier.Interpreter.ExitEntryStatesToInvokeTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, MachineState, Parser, Validator}
  alias Statifier.Interpreter.ExitEntry

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root)
  #  1   start   (transition "go" -> mid)
  #  2   mid     (no <invoke> children; transition "leave" -> done)
  #  3   done
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="start">
      <state id="start">
          <transition event="go" target="mid"/>
      </state>
      <state id="mid">
          <transition event="leave" target="done"/>
      </state>
      <state id="done"/>
  </scxml>
  """

  @indexes %{start: 1, mid: 2, done: 3}

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration) do
    %{MachineState.new(machine) | configuration: MapSet.new(configuration)}
  end

  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  # AC: "entering a state adds its index unconditionally (including a state
  # with no <invoke>)" - `mid` carries no `<invoke>` children at all, which
  # is the point: `arrive/3` does not consult `state.invoke` before adding.
  #
  # sabotage: `arrive/3`'s `states_to_invoke: MapSet.put(...)` rebind is
  # deleted -> `result.states_to_invoke` comes back empty, reddening this
  # assertion.
  test "entering a state adds its index to states_to_invoke unconditionally" do
    m = machine()
    ms = machine_state(m, [])
    transition = transition_named(m, "go")

    {result, _effects} = ExitEntry.enter_states(ms, [transition])

    assert MapSet.member?(result.states_to_invoke, idx(:mid))
  end

  # AC: "exiting removes it"
  #
  # sabotage: `exit_states/2`'s `states_to_invoke: MapSet.difference(...)`
  # rebind is changed to `MapSet.union/2` -> `mid`'s index would survive the
  # exit instead of being removed, reddening this refutation.
  test "exiting a state removes its index from states_to_invoke" do
    m = machine()

    ms = %{
      machine_state(m, [idx(:mid)])
      | states_to_invoke: MapSet.new([idx(:mid)])
    }

    transition = transition_named(m, "leave")

    {result, _effects} = ExitEntry.exit_states(ms, [transition])

    refute MapSet.member?(result.states_to_invoke, idx(:mid))
  end

  # AC: "We may enter state s in m11 and exit it in m12" (spec 6.4's own
  # prose motivating why the invoke pass runs the state's *current*
  # membership at the end of the macrostep, not a snapshot taken at entry) -
  # entering and exiting a state across two microsteps of the same macrostep,
  # with no invoke pass in between, must leave it absent from
  # `states_to_invoke` by the time the macrostep ends.
  #
  # sabotage: `exit_states/2`'s `states_to_invoke: MapSet.difference(...)`
  # is changed to `MapSet.union/2` -> `mid`'s index, added by the prior
  # `enter_states/2` call, would still be present after exiting, reddening
  # this refutation.
  test "a state entered then exited within one macrostep ends up absent" do
    m = machine()
    ms0 = machine_state(m, [idx(:start)])
    enter_transition = transition_named(m, "go")
    exit_transition = transition_named(m, "leave")

    {ms1, _effects} = ExitEntry.enter_states(ms0, [enter_transition])
    assert MapSet.member?(ms1.states_to_invoke, idx(:mid))

    {ms2, _effects} = ExitEntry.exit_states(ms1, [exit_transition])

    refute MapSet.member?(ms2.states_to_invoke, idx(:mid))
  end
end
