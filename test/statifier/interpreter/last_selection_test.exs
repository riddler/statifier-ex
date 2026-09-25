defmodule Statifier.Interpreter.LastSelectionTest do
  use ExUnit.Case, async: true

  alias Statifier.{Event, Interpreter, MachineState, Position}

  # `%MachineState{}.last_selection` records whether the external event
  # `Interpreter.handle_event/2` was handed selected any transition:
  # `:selected` or `:none`, `nil` before any external event. Its one writer
  # is `handle_event/2`, and it is written whether or not the position was
  # created with tracing.
  #
  # `a` has a self-transition on `again`, a transition on `guarded` whose
  # guard is false, and no transition at all for any other name. `go`
  # leaves for `b`, whose entry raises `ping` and whose eventless
  # transition leaves for `c` - so after `go`'s own selection the
  # macrostep keeps folding through eventless and internal rounds, and its
  # last round is always an empty eventless probe.
  @xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="again" target="a"/>
          <transition event="guarded" cond="false" target="b"/>
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <onentry><raise event="ping"/></onentry>
          <transition target="c"/>
      </state>
      <state id="c">
          <transition event="ping" target="d"/>
      </state>
      <state id="d"/>
  </scxml>
  """

  defp machine do
    {:ok, machine} = Statifier.compile(@xml)
    machine
  end

  defp initialized(opts \\ []) do
    {machine_state, _effects} = Interpreter.initialize(machine(), opts)
    machine_state
  end

  defp deliver(machine_state, name) do
    {:ok, machine_state, _effects} =
      Interpreter.handle_event(machine_state, Event.external(name))

    machine_state
  end

  defp active_ids(machine_state) do
    machine_state.configuration
    |> Enum.map(&Statifier.Machine.id(machine_state.machine, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  describe "before any external event" do
    # sabotage: the struct default `last_selection: nil` is changed to
    # `:none` -> both assertions redden: a fresh state and an initialized
    # one read the default until an external event is handled.
    test "a fresh and an initialized state read nil" do
      assert MachineState.new(machine()).last_selection == nil
      assert initialized().last_selection == nil
    end
  end

  describe "handle_event/2 stamps the external event's selection" do
    # sabotage: `handle_event/2`'s stamp is changed to always write
    # `:none` -> reddens: the self-transition selected one transition.
    test "a self-transition reads :selected" do
      machine_state = deliver(initialized(), "again")

      assert active_ids(machine_state) == ["a"]
      assert machine_state.last_selection == :selected
    end

    # sabotage: `handle_event/2`'s stamp is changed to always write
    # `:selected` -> both assertions redden: an event no transition
    # names, and one whose only transition's guard is false, select
    # nothing.
    test "an ignored event reads :none, whether unnamed or guarded out" do
      unnamed = deliver(initialized(), "nobody_listens")
      assert active_ids(unnamed) == ["a"]
      assert unnamed.last_selection == :none

      guarded = deliver(initialized(), "guarded")
      assert active_ids(guarded) == ["a"]
      assert guarded.last_selection == :none
    end

    # sabotage: the stamp is moved into the private `run_selected/3`
    # (every selection site: the external event, each internal event and
    # each eventless probe), writing `:selected` on a non-empty list and
    # `:none` on an empty one -> reddens: `go`'s macrostep ends on an empty
    # eventless probe after `b`'s eventless transition and `ping`'s round,
    # so the last write would be `:none`.
    test "an external event followed by eventless and internal rounds reads :selected" do
      machine_state = deliver(initialized(), "go")

      assert active_ids(machine_state) == ["d"]
      assert machine_state.last_selection == :selected
    end

    # sabotage: the stamp is changed to write only on a non-empty
    # selection (keeping the previous value otherwise) -> reddens: the
    # second, ignored event would still read the first event's `:selected`.
    test "each external event overwrites the previous stamp" do
      machine_state = initialized() |> deliver("again") |> deliver("nobody_listens")

      assert machine_state.last_selection == :none

      assert deliver(machine_state, "again").last_selection == :selected
    end

    # sabotage: the stamp is made conditional on `machine_state.trace` ->
    # the untraced half reddens.
    test "the stamp is written with and without tracing" do
      for trace <- [false, true] do
        assert deliver(initialized(trace: trace), "again").last_selection == :selected
        assert deliver(initialized(trace: trace), "nobody_listens").last_selection == :none
      end
    end
  end

  describe "other entry points" do
    # sabotage: `deliver_internal/5` is changed to write `:none` after its
    # fold -> reddens: an internal delivery is not an external event, so
    # the previous external event's stamp stands.
    test "deliver_internal/5 leaves the stamp where it stood" do
      machine_state = deliver(initialized(), "again")

      assert {:ok, machine_state, _effects} =
               Interpreter.deliver_internal(machine_state, :internal, "e", {:state, 0}, [])

      assert machine_state.last_selection == :selected
    end
  end

  describe "a persisted position" do
    # sabotage: `:last_selection` is removed from `to_binary/1`'s drop list
    # -> the `refute` reddens: the payload carries the key.
    test "does not carry the stamp; a restored state reads nil" do
      machine_state = deliver(initialized(), "again")
      assert machine_state.last_selection == :selected

      assert {:ok, blob} = Position.to_binary(machine_state)

      {:statifier_position, _version, _identity, payload} = :erlang.binary_to_term(blob)
      refute Map.has_key?(payload, :last_selection)

      assert {:ok, restored} = Position.from_binary(blob, machine_state.machine)
      assert restored.last_selection == nil
    end

    # sabotage: `:last_selection` is removed from `from_binary/2`'s drop
    # list -> reddens: a hand-written blob carrying the key would restore
    # it.
    test "a blob that carries the key still restores nil" do
      machine_state = deliver(initialized(), "again")
      identity = Statifier.Machine.identity(machine_state.machine)

      payload =
        machine_state
        |> Map.from_struct()
        |> Map.drop([:machine, :routes, :invoke_types, :send_types])

      blob =
        :erlang.term_to_binary(
          {:statifier_position, Position.format_version(), identity, payload}
        )

      assert {:ok, restored} = Position.from_binary(blob, machine_state.machine)
      assert restored.last_selection == nil
    end
  end
end
