defmodule Statifier.PositionTest do
  use ExUnit.Case, async: true

  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.{Machine, MachineState, Position}
  alias Statifier.Send.Routes

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

  # @xml with "b" and "outside" both removed - an unknown-id fixture for
  # `import/2`, not a whitespace edit. "a" keeps no outgoing transition
  # since its only target ("b") no longer exists.
  @xml_two_states_removed """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <history id="h" type="shallow">
              <transition target="a"/>
          </history>
          <state id="a"/>
      </state>
  </scxml>
  """

  # A nameless state as the default (first-child) initial of "p" - an
  # unnameable-active-state fixture for `export/1`.
  @xml_nameless_active_state """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <state id="p">
          <state>
              <transition event="go" target="p"/>
          </state>
      </state>
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

    # sabotage: same mutation as above (`from_binary/2`'s catch-all
    # `_other -> {:error, :not_a_statifier_blob}` clause's returned atom
    # changed to `:invalid_blob`) -> this test reddens too, since a random
    # binary reaches the same catch-all via `safe_decode/1`'s `rescue`
    # clause rather than a non-matching decoded term
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

  describe "export/1 then import/2 round trip against the same machine" do
    # sabotage: `translate_index_set/2`'s `Enum.reject(&is_nil/1)` filter is
    # dropped, so the root index's own `nil` id survives translation and
    # lands in `exported.configuration` as a literal `nil` member -> this
    # test reddens because `Position.import/2` now returns
    # `{:error, {:malformed_export, {:configuration, _}}}` (the shape check
    # rejects the stray `nil`) instead of `{:ok, _}`
    test "reproduces every translated field of a machine_state advanced by real send_event/2 calls" do
      machine = compile!(@xml)
      machine_state = advanced_machine_state(machine)

      assert {:ok, exported} = Position.export(machine_state)
      assert {:ok, imported} = Position.import(machine, exported)

      assert MachineState.internal_events(imported) == []
      assert MachineState.internal_events(machine_state) == []

      assert %MachineState{
               machine: ^machine,
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
               routes: nil,
               invoke_types: nil
             } = imported

      assert configuration == machine_state.configuration
      assert history_values == machine_state.history_values
      assert entered_states == machine_state.entered_states
      assert states_to_invoke == machine_state.states_to_invoke
      assert active_invocations == machine_state.active_invocations
      assert invoke_counter == machine_state.invoke_counter
      assert send_counter == machine_state.send_counter
      assert datamodel == machine_state.datamodel
      assert running == machine_state.running
      assert status == machine_state.status
      assert macrostep == machine_state.macrostep
      assert microstep == machine_state.microstep
      assert round == machine_state.round
      assert trace == machine_state.trace
      assert max_macrostep_rounds == machine_state.max_macrostep_rounds
    end
  end

  describe "export/1 then import/2 across a chart revision with an unrelated state added" do
    # sabotage: `unnameable_indexes/2`'s root exception (`&1 != 0`) is
    # dropped, so index `0` is treated as unnameable too -> this test
    # reddens because `Position.export/1` now returns `{:error,
    # {:unnameable_states, [0]}}` instead of `{:ok, _}`
    test "every original id still resolves and the resulting configuration is the same set of ids" do
      machine_a = compile!(@xml)
      machine_state = advanced_machine_state(machine_a)
      assert {:ok, exported} = Position.export(machine_state)

      machine_b = compile!(@xml_one_state_added)
      assert {:ok, imported} = Position.import(machine_b, exported)

      assert MapSet.member?(imported.configuration, 0)

      imported_ids =
        imported.configuration
        |> MapSet.delete(0)
        |> MapSet.new(&Machine.id(machine_b, &1))

      assert imported_ids == exported.configuration
    end
  end

  describe "export/1 then import/2 across a chart revision that removed active states" do
    # sabotage: `collect_unknown_ids/2`'s `Machine.index(machine, &1) ==
    # :error` filter is replaced with `fn _id -> true end` (every id looks
    # unknown) -> this test reddens because the returned list gains every
    # other id the position touches ("a", "h", "p") instead of naming only
    # the two ids the new chart revision actually dropped
    test "returns {:error, {:unknown_state_ids, ids}} listing all of them, not just the first" do
      machine_a = compile!(@xml)
      machine_state = advanced_machine_state(machine_a)
      assert {:ok, exported} = Position.export(machine_state)

      assert MapSet.member?(exported.configuration, "b")

      machine_b = compile!(@xml_two_states_removed)

      assert Position.import(machine_b, exported) ==
               {:error, {:unknown_state_ids, ["b", "outside"]}}
    end
  end

  describe "export/1 on a machine_state with a non-empty internal_queue" do
    # sabotage: `export/1`'s `if MachineState.internal_queue_empty?(...)`
    # branch is inverted -> this test reddens because a non-empty queue now
    # exports successfully instead of returning
    # `{:error, :internal_queue_not_empty}`
    test "returns {:error, :internal_queue_not_empty}" do
      machine = compile!(@xml)

      machine_state =
        machine
        |> MachineState.new()
        |> MachineState.raise_internal("test.event", {:state, 0})

      refute MachineState.internal_queue_empty?(machine_state)
      assert Position.export(machine_state) == {:error, :internal_queue_not_empty}
    end
  end

  describe "export/1 then import/2 of history_values" do
    # sabotage: `translate_history_values/2`'s `Machine.id(machine, key)`
    # lookup is replaced with a hardcoded `nil` (as if every history key
    # were unnameable) -> this test reddens because `exported.history_values`
    # comes back `%{}` instead of carrying the "h" => "b" entry the real run
    # produced
    test "survives a round trip with keys and values both translated to string ids" do
      machine = compile!(@xml)
      machine_state = advanced_machine_state(machine)
      refute machine_state.history_values == %{}

      assert {:ok, exported} = Position.export(machine_state)

      assert %{"h" => value_ids} = exported.history_values
      assert MapSet.equal?(value_ids, MapSet.new(["b"]))

      assert {:ok, imported} = Position.import(machine, exported)
      assert imported.history_values == machine_state.history_values
    end
  end

  describe "export/1 then import/2 of active_invocations" do
    # sabotage: `translate_active_invocations/2`'s key construction is
    # changed from `{state_id, invoke_index}` to `{state_id, invoke_index +
    # 1}` -> this test reddens because `exported.active_invocations`'s key
    # carries the wrong `invoke_index`
    test "survives a round trip with its invoke_index intact" do
      machine = compile!(@xml)
      {:ok, state_b_index} = Machine.index(machine, "b")

      machine_state = %{
        MachineState.new(machine)
        | configuration: MapSet.new([0, state_b_index]),
          active_invocations: %{{state_b_index, 2} => "inv_2"}
      }

      assert {:ok, exported} = Position.export(machine_state)
      assert exported.active_invocations == %{{"b", 2} => "inv_2"}

      assert {:ok, imported} = Position.import(machine, exported)
      assert imported.active_invocations == %{{state_b_index, 2} => "inv_2"}
    end
  end

  describe "export/1 on a chart with a nameless non-root state active" do
    # sabotage: `unnameable_indexes/2`'s `is_nil(Machine.id(machine, &1))`
    # check is replaced with `false` (nothing is ever unnameable) -> this
    # test reddens because `export/1` returns `{:ok, _}` instead of
    # `{:error, {:unnameable_states, _}}`
    test "returns {:error, {:unnameable_states, _}}" do
      machine = compile!(@xml_nameless_active_state)
      {machine_state, _effects} = Statifier.initialize(machine)

      assert {:error, {:unnameable_states, unnameable}} = Position.export(machine_state)
      assert unnameable != []
      refute Enum.member?(unnameable, 0)
    end
  end

  describe "export/1 then import/2 drop routes and invoke_types" do
    # sabotage: `build_machine_state/2`'s `routes: nil` and
    # `invoke_types: nil` literals are changed to
    # `routes: :sabotage, invoke_types: :sabotage` -> this test reddens
    # because `imported.routes`/`imported.invoke_types` no longer equal `nil`
    test "routes and invoke_types set before export come back nil after import, not tolerated as absent" do
      machine = compile!(@xml)

      machine_state = %{
        MachineState.new(machine)
        | routes: Routes.new(sessions: ["sess_other"]),
          invoke_types: InvokeTypes.new(types: ["http://example.com/custom"])
      }

      assert {:ok, exported} = Position.export(machine_state)
      refute Map.has_key?(exported, :routes)
      refute Map.has_key?(exported, :invoke_types)

      assert {:ok, imported} = Position.import(machine, exported)
      assert imported.routes == nil
      assert imported.invoke_types == nil
    end
  end

  describe "import/2 on a malformed export" do
    # sabotage: `check_required_keys/1`'s `Map.has_key?(exported, &1)` guard
    # is replaced with `true` (every key looks present) -> this test reddens
    # because `import/2` now tries to build a `MachineState` from a map with
    # no `:datamodel` key and raises `KeyError` instead of returning
    # `{:error, {:malformed_export, _}}`
    test "an export map with a key deleted returns {:error, {:malformed_export, _}}" do
      machine = compile!(@xml)
      machine_state = MachineState.new(machine)

      assert {:ok, exported} = Position.export(machine_state)
      malformed = Map.delete(exported, :datamodel)

      assert {:error, {:malformed_export, _reason}} = Position.import(machine, malformed)
    end
  end

  describe "import/2 ignores the :identity key entirely" do
    # sabotage: an `Identity.matches?/2` guard is added to `import/2`
    # (rejecting an `:identity` value that does not match `machine`'s own,
    # via `Machine.identity/1`) -> both assertions below redden, since a
    # `:garbage` identity and a missing one would both now fail import
    # instead of succeeding identically to a correct one
    test "a tampered or missing :identity value imports identically to a correct one" do
      machine = compile!(@xml)
      machine_state = MachineState.new(machine)
      assert {:ok, exported} = Position.export(machine_state)

      tampered = %{exported | identity: :garbage}
      assert {:ok, _imported} = Position.import(machine, tampered)

      no_identity = Map.delete(exported, :identity)
      assert {:ok, _imported} = Position.import(machine, no_identity)
    end
  end
end
