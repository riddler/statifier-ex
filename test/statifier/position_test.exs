defmodule Statifier.PositionTest do
  use ExUnit.Case, async: true

  alias Statifier.{Machine, MachineState, Position}

  @xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <history id="h" type="shallow">
              <transition target="a"/>
          </history>
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
              </onentry>
              <transition event="leave" target="outside"/>
          </state>
      </state>
      <state id="outside">
          <transition event="back" target="h"/>
      </state>
  </scxml>
  """

  # One state added relative to @xml - an identity-mismatch fixture, not a
  # whitespace edit.
  @xml_one_state_added """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <history id="h" type="shallow">
              <transition target="a"/>
          </history>
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
              </onentry>
              <transition event="leave" target="outside"/>
          </state>
      </state>
      <state id="outside">
          <transition event="back" target="h"/>
      </state>
      <state id="extra"/>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # A position advanced past a fresh `new/2`: goes p/a -> p/b (bumping
  # `count` and history) -> outside -> back into `p` via shallow history,
  # so `history_values`, the datamodel, and the step counters are all
  # non-trivial.
  defp advanced_machine_state(machine) do
    {machine_state, _effects} = Statifier.initialize(machine)
    {:ok, machine_state, _effects} = Statifier.send_event(machine_state, "go")
    {:ok, machine_state, _effects} = Statifier.send_event(machine_state, "leave")
    {:ok, machine_state, _effects} = Statifier.send_event(machine_state, "back")
    machine_state
  end

  describe "to_binary/1 then from_binary/2 round trip" do
    # sabotage: `from_binary/2`'s success arm is changed from
    # `struct!(MachineState, Map.put(payload, :machine, machine))` to
    # `MachineState.new(machine)` (rebuild fresh instead of restoring the
    # decoded payload) -> every non-default field assertion below reddens,
    # since a freshly built machine_state has an empty configuration, no
    # history, and the datamodel back at its `new/2` seed
    test "reproduces every field of a machine_state built by MachineState.new/2" do
      machine = compile!(@xml)
      machine_state = MachineState.new(machine)

      %MachineState{
        configuration: configuration,
        history_values: history_values,
        entered_states: entered_states,
        states_to_invoke: states_to_invoke,
        active_invocations: active_invocations,
        invoke_counter: invoke_counter,
        send_counter: send_counter,
        datamodel: datamodel,
        running: running,
        status: status,
        macrostep: macrostep,
        microstep: microstep,
        round: round,
        trace: trace,
        max_macrostep_rounds: max_macrostep_rounds,
        routes: routes,
        invoke_types: invoke_types
      } = machine_state

      assert {:ok, blob} = Position.to_binary(machine_state)
      assert {:ok, decoded} = Position.from_binary(blob, machine)

      assert MachineState.internal_events(decoded) == MachineState.internal_events(machine_state)

      assert %MachineState{
               machine: ^machine,
               configuration: ^configuration,
               history_values: ^history_values,
               entered_states: ^entered_states,
               states_to_invoke: ^states_to_invoke,
               active_invocations: ^active_invocations,
               invoke_counter: ^invoke_counter,
               send_counter: ^send_counter,
               datamodel: ^datamodel,
               running: ^running,
               status: ^status,
               macrostep: ^macrostep,
               microstep: ^microstep,
               round: ^round,
               trace: ^trace,
               max_macrostep_rounds: ^max_macrostep_rounds,
               routes: ^routes,
               invoke_types: ^invoke_types
             } = decoded
    end

    # sabotage: same mutation as above (`from_binary/2`'s success arm
    # rebuilds fresh via `MachineState.new(machine)` instead of restoring
    # the decoded payload) -> the history_values/datamodel/counter
    # assertions below reddens, since a fresh machine_state has none of
    # the state a real send_event/2 sequence produced
    test "reproduces every field of a machine_state advanced by real send_event/2 calls" do
      machine = compile!(@xml)
      machine_state = advanced_machine_state(machine)

      # A real run genuinely exercised history and the datamodel - assert
      # that before round-tripping, so the round trip below is proven to
      # carry non-trivial state rather than defaults that would round trip
      # trivially either way.
      refute machine_state.history_values == %{}
      assert machine_state.datamodel["count"] == 2
      assert machine_state.macrostep > 0

      %MachineState{
        configuration: configuration,
        history_values: history_values,
        entered_states: entered_states,
        states_to_invoke: states_to_invoke,
        active_invocations: active_invocations,
        invoke_counter: invoke_counter,
        send_counter: send_counter,
        datamodel: datamodel,
        running: running,
        status: status,
        macrostep: macrostep,
        microstep: microstep,
        round: round,
        trace: trace,
        max_macrostep_rounds: max_macrostep_rounds,
        routes: routes,
        invoke_types: invoke_types
      } = machine_state

      assert {:ok, blob} = Position.to_binary(machine_state)
      assert {:ok, decoded} = Position.from_binary(blob, machine)

      assert MachineState.internal_events(decoded) == MachineState.internal_events(machine_state)

      assert %MachineState{
               machine: ^machine,
               configuration: ^configuration,
               history_values: ^history_values,
               entered_states: ^entered_states,
               states_to_invoke: ^states_to_invoke,
               active_invocations: ^active_invocations,
               invoke_counter: ^invoke_counter,
               send_counter: ^send_counter,
               datamodel: ^datamodel,
               running: ^running,
               status: ^status,
               macrostep: ^macrostep,
               microstep: ^microstep,
               round: ^round,
               trace: ^trace,
               max_macrostep_rounds: ^max_macrostep_rounds,
               routes: ^routes,
               invoke_types: ^invoke_types
             } = decoded
    end

    # sabotage: `to_binary/1`'s `Map.delete(:machine)` call is dropped, so
    # the payload keeps its `:machine` key -> both assertions below redden:
    # the blob is no longer materially smaller than a naive
    # `term_to_binary(machine_state)`, and the raw-decoded payload map does
    # carry a `:machine` key
    test "the blob does not contain the machine" do
      machine = compile!(@xml)
      machine_state = advanced_machine_state(machine)

      assert {:ok, blob} = Position.to_binary(machine_state)

      naive_size = byte_size(:erlang.term_to_binary(machine_state))
      assert byte_size(blob) < div(naive_size, 2)

      assert {:statifier_position, 1, _identity, payload} = :erlang.binary_to_term(blob)
      refute Map.has_key?(payload, :machine)
    end
  end

  describe "to_binary/1 on an unidentified chart" do
    # sabotage: `to_binary/1`'s `identity: nil` guard clause is dropped, so
    # a `nil`-identity machine_state falls through to the general clause
    # instead -> this test reddens because `to_binary/1` returns `{:ok, _}`
    # for an unidentified chart instead of `{:error, :unidentified_chart}`
    test "returns {:error, :unidentified_chart} for a Machine with no identity" do
      machine = %Machine{compile!(@xml) | identity: nil}
      machine_state = MachineState.new(machine)

      assert Position.to_binary(machine_state) == {:error, :unidentified_chart}
    end
  end

  describe "from_binary/2 identity checks" do
    # sabotage: `check_identity/2`'s `Identity.matches?/2` branch is
    # replaced with the mismatch branch unconditionally
    # (`{:error, {:identity_mismatch, blob_identity, machine_identity}}`
    # always) -> this test reddens because loading against a freshly
    # recompiled, byte-identical source now errors instead of succeeding
    test "loading against a recompiled identical source succeeds" do
      machine_a = compile!(@xml)
      machine_state = advanced_machine_state(machine_a)
      assert {:ok, blob} = Position.to_binary(machine_state)

      machine_b = compile!(@xml)
      assert {:ok, decoded} = Position.from_binary(blob, machine_b)
      assert decoded.machine == machine_b
    end

    # This is the bead's central test: an interned-index position must
    # never silently resume against a chart revision that changed the
    # index space.
    #
    # sabotage: `check_identity/2`'s condition is inverted (`if
    # !Identity.matches?(...)` instead of `if Identity.matches?(...)`) ->
    # this test reddens because loading against a chart with one state
    # added now succeeds instead of returning `{:error,
    # {:identity_mismatch, _, _}}`
    test "loading against a chart with one state added returns {:error, {:identity_mismatch, _, _}}" do
      machine_a = compile!(@xml)
      machine_state = advanced_machine_state(machine_a)
      assert {:ok, blob} = Position.to_binary(machine_state)

      machine_b = compile!(@xml_one_state_added)

      assert {:error, {:identity_mismatch, expected, actual}} =
               Position.from_binary(blob, machine_b)

      assert expected == Machine.identity(machine_a)
      assert actual == Machine.identity(machine_b)
    end

    # sabotage: `check_identity/2`'s `identity: nil` clause is dropped, so a
    # `nil`-identity machine falls through to the general clause instead ->
    # this test reddens because loading against an unidentified machine now
    # returns `{:error, {:identity_mismatch, _, nil}}` instead of
    # `{:error, :unidentified_chart}`
    test "loading against a Machine with no identity returns {:error, :unidentified_chart}" do
      machine_a = compile!(@xml)
      machine_state = advanced_machine_state(machine_a)
      assert {:ok, blob} = Position.to_binary(machine_state)

      unidentified_machine = %Machine{machine_a | identity: nil}

      assert Position.from_binary(blob, unidentified_machine) == {:error, :unidentified_chart}
    end
  end

  describe "from_binary/2 format version checks" do
    # sabotage: `check_version/1`'s exact-match clause head is widened from
    # `defp check_version(@format_version)` to `defp check_version(_version)`
    # (accept any version) -> this test reddens because a blob whose version
    # integer is bumped to 2 now loads instead of returning
    # `{:error, {:unsupported_format_version, 2}}`
    test "a blob whose version integer is bumped returns {:error, {:unsupported_format_version, 2}}" do
      machine = compile!(@xml)
      identity = Machine.identity(machine)
      machine_state = MachineState.new(machine)
      payload = machine_state |> Map.from_struct() |> Map.delete(:machine)

      future_blob = :erlang.term_to_binary({:statifier_position, 2, identity, payload})

      assert Position.from_binary(future_blob, machine) ==
               {:error, {:unsupported_format_version, 2}}
    end
  end

  describe "from_binary/2 on a foreign or malformed blob" do
    # sabotage: `from_binary/2`'s catch-all `_other -> {:error,
    # :not_a_statifier_blob}` clause's returned atom is changed from
    # `:not_a_statifier_blob` to `:invalid_blob` -> both assertions below
    # redden because the actual returned error atom no longer matches
    test "a foreign term_to_binary blob returns {:error, :not_a_statifier_blob}" do
      machine = compile!(@xml)

      assert Position.from_binary(:erlang.term_to_binary(:hello), machine) ==
               {:error, :not_a_statifier_blob}
    end

    test "a random binary returns {:error, :not_a_statifier_blob} rather than raising" do
      machine = compile!(@xml)
      random_binary = :crypto.strong_rand_bytes(64)

      assert Position.from_binary(random_binary, machine) == {:error, :not_a_statifier_blob}
    end
  end

  describe "format_version/0" do
    # sabotage: `format_version/0` is changed to return `@format_version +
    # 1` instead of `@format_version` -> this test reddens because the
    # returned value (2) no longer equals the version tag actually written
    # into every blob by `to_binary/1`
    test "matches the version tag to_binary/1 writes" do
      machine = compile!(@xml)
      machine_state = MachineState.new(machine)

      assert {:ok, blob} = Position.to_binary(machine_state)
      assert {:statifier_position, version, _identity, _payload} = :erlang.binary_to_term(blob)
      assert version == Position.format_version()
    end
  end

  describe "an ADR-0037 :undefined datamodel value and a nil datamodel value" do
    # sabotage: `from_binary/2`'s success arm is changed from
    # `struct!(MachineState, Map.put(payload, :machine, machine))` to
    # `MachineState.new(machine)` (rebuild fresh instead of restoring the
    # decoded payload) -> this test reddens because the decoded datamodel no
    # longer carries either "undefined_var" or "null_var" at all
    test "survive the round trip distinctly" do
      machine = compile!(@xml)

      machine_state =
        MachineState.new(machine, datamodel: %{"undefined_var" => :undefined, "null_var" => nil})

      assert {:ok, blob} = Position.to_binary(machine_state)
      assert {:ok, decoded} = Position.from_binary(blob, machine)

      assert decoded.datamodel["undefined_var"] == :undefined
      assert decoded.datamodel["null_var"] == nil
      refute decoded.datamodel["undefined_var"] == decoded.datamodel["null_var"]
    end
  end
end
