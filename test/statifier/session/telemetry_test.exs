defmodule Statifier.Session.TelemetryTest do
  use ExUnit.Case, async: false

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.DatamodelChange
  alias Statifier.Effect.DatamodelInit
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Machine
  alias Statifier.Session
  alias Statifier.Session.Telemetry

  # Handlers are global to the VM (`:telemetry.attach_many/4` registers on a
  # shared name), so this file is `async: false` - a concurrently running
  # test file's sessions would otherwise deliver into this mailbox too.
  # `on_exit/1` detaching mirrors `test/mix/tasks/adr_judge_test.exs:346`'s
  # own use of it for cleanup: the alternative is a leaked handler that keeps
  # firing into a dead test process for the rest of the suite.
  setup do
    ref = :telemetry_test.attach_event_handlers(self(), Telemetry.events())
    on_exit(fn -> :telemetry.detach(ref) end)
    {:ok, ref: ref}
  end

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # One `<log>` (a real `c_index`), one outgoing transition (unused for
  # `t_index` - see the location test's own note), two states (a real
  # `state_index` for "a"). Reused across tests that need a real `Machine`
  # to resolve a location against, since none of the location-resolution
  # behavior depends on which document produced the machine.
  defp located_machine do
    compile!("""
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <log label="hi"/>
            </onentry>
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """)
  end

  defp drain(ref, acc \\ []) do
    receive do
      {event, ^ref, measurements, metadata} -> drain(ref, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # -- fixtures for the Phase 3 integration tests (a live Statifier.Session) --

  defp two_state_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  defp final_on_event_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="finish" target="fin"/>
        </state>
        <final id="fin"/>
    </scxml>
    """
  end

  defp livelock_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition target="a"/>
        </state>
    </scxml>
    """
  end

  # A `#_internal` send fired from `<onentry>` self-delivers through
  # ADR-0039 re-entry (`Interpreter.deliver_internal/5`), opening a nested
  # `trigger: :internal` macrostep span inside the enclosing span - the
  # `:initialize` span here, since the send fires on entry to the initial
  # state. Mirrors `internal_send_doc/1` in `test/statifier/session_test.exs`.
  defp internal_send_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <send event="e" target="#_internal"/>
            </onentry>
            <transition event="e" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  defp wait_for_status(session, pred, attempts \\ 50)

  defp wait_for_status(_session, _pred, 0), do: flunk("status/1 never satisfied the predicate")

  defp wait_for_status(session, pred, attempts) do
    status = Session.status(session)

    if pred.(status) do
      status
    else
      Process.sleep(2)
      wait_for_status(session, pred, attempts - 1)
    end
  end

  @core_fixtures [
    {:send,
     %Send{
       event: "e",
       target: "#_parent",
       send_id: "s1",
       c_index: nil,
       owner: nil,
       macrostep: 1,
       microstep: 2,
       round: 1
     }},
    {:send_delayed,
     %SendDelayed{
       event: "e",
       delay_ms: 250,
       target: "#_parent",
       send_id: "s2",
       c_index: nil,
       owner: nil,
       macrostep: 1,
       microstep: 2,
       round: 1
     }},
    {:cancel,
     %Cancel{send_id: "s3", c_index: nil, owner: nil, macrostep: 1, microstep: 2, round: 1}},
    {:invoke,
     %Invoke{
       invoke_id: "i1",
       state_index: 0,
       invoke_index: 0,
       macrostep: 1,
       microstep: 2,
       round: 1
     }},
    {:cancel_invoke,
     %CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 2, round: 1}},
    {:autoforward,
     %Autoforward{
       invoke_id: "i1",
       state_index: 0,
       event: Event.external("e"),
       macrostep: 1,
       microstep: 2,
       round: 1
     }},
    {:budget_exhausted,
     %BudgetExhausted{
       configuration: MapSet.new(),
       budget: 5,
       pending_internal_events: [],
       macrostep: 1,
       microstep: 0,
       round: 5
     }},
    {:done, %Done{configuration: MapSet.new(), macrostep: 1, microstep: 2, round: 1}},
    {:log, %Log{label: "l", c_index: nil, owner: nil, macrostep: 1, microstep: 2, round: 1}}
  ]

  @trace_fixtures [
    {:event_dequeued,
     {:trace,
      %Trace.EventDequeued{
        event: Event.external("e"),
        from: :external,
        macrostep: 1,
        microstep: 1,
        round: 0
      }}},
    {:transitions_selected,
     {:trace,
      %Trace.TransitionsSelected{t_indexes: [], event: nil, macrostep: 1, microstep: 1, round: 0}}},
    {:exit_set, {:trace, %Trace.ExitSet{indexes: [], macrostep: 1, microstep: 1, round: 0}}},
    {:content_executed,
     {:trace,
      %Trace.ContentExecuted{
        owner: {:transition, 0},
        c_indexes: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }}},
    {:entry_set, {:trace, %Trace.EntrySet{indexes: [], macrostep: 1, microstep: 1, round: 0}}},
    {:macrostep_stable,
     {:trace,
      %Trace.MacrostepStable{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}}},
    {:done,
     {:trace, %Trace.Done{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}}},
    {:invoke_pass,
     {:trace,
      %Trace.InvokePass{state_indexes: [], invoke_ids: [], macrostep: 1, microstep: 1, round: 0}}},
    {:finalize_autoforward,
     {:trace,
      %Trace.FinalizeAutoforward{
        event: Event.external("e"),
        finalized: [],
        forwarded: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }}}
  ]

  describe "events/0" do
    # sabotage: `@effect_kinds` drops `:log` -> red, `length(events) == 27`
    # fails (26 names) - reverted and confirmed green.
    test "returns exactly 27 names, all `[:statifier, :session | _]`" do
      events = Telemetry.events()

      assert length(events) == 27
      assert Enum.uniq(events) == events

      assert Enum.all?(events, fn
               [:statifier, :session | _rest] -> true
               _other -> false
             end)
    end

    # sabotage: the moduledoc's `:log` row (`| \`[:statifier, :session,
    # :effect, :log]\` | ...`) is deleted -> red, the moduledoc's extracted
    # event set is missing `[:statifier, :session, :effect, :log]` while
    # `events/0` still has it, so the `MapSet` equality assertion fails -
    # reverted and confirmed green.
    test "and the moduledoc's tables name exactly the same events" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Telemetry)

      documented =
        ~r/\[:statifier(?:, :[a-zA-Z_]+)+\]/
        |> Regex.scan(moduledoc)
        |> List.flatten()
        |> Enum.map(&Code.string_to_quoted!/1)
        |> MapSet.new()

      assert documented == MapSet.new(Telemetry.events())
    end
  end

  describe "init/4" do
    # sabotage: `init/4`'s metadata swaps `machine.name` for a hardcoded
    # `nil` -> red, `metadata.machine_name == "m"` fails - reverted and
    # confirmed green.
    test "emits system_time and the session/machine identity", %{ref: ref} do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="m" initial="a">
            <state id="a"/>
        </scxml>
        """)

      {machine_state, _effects} = Statifier.initialize(machine, trace: true)

      assert :ok = Telemetry.init("sess1", machine, machine_state, {self(), "inv1"})

      assert_received {[:statifier, :session, :init], ^ref, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.session_id == "sess1"
      assert metadata.machine_name == "m"
      assert metadata.trace == true
      assert metadata.invoked_by == {self(), "inv1"}
    end
  end

  describe "halt/3" do
    # sabotage: `halt/3`'s measurements map hardcodes `round: 0` instead of
    # reading `machine_state.round` -> red, `measurements.round ==
    # machine_state.round` fails whenever the machine actually advanced a
    # round - reverted and confirmed green.
    test "emits the step counters and a state-id configuration", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert :ok = Telemetry.halt("sess1", :done, machine_state)

      assert_received {[:statifier, :session, :halt], ^ref, measurements, metadata}
      assert measurements.macrostep == machine_state.macrostep
      assert measurements.microstep == machine_state.microstep
      assert measurements.round == machine_state.round
      assert metadata.reason == :done
      assert metadata.configuration == MapSet.new(["a"])
    end
  end

  describe "terminate/4" do
    # sabotage: `terminate/4` drops `status` from its metadata map -> red,
    # `metadata.status` no longer exists so `metadata.status == :done` raises
    # a `KeyError` instead of matching - reverted and confirmed green.
    test "emits the GenServer reason and status", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert :ok = Telemetry.terminate("sess1", :normal, :done, machine_state)

      assert_received {[:statifier, :session, :terminate], ^ref, measurements, metadata}
      assert measurements.macrostep == machine_state.macrostep
      assert metadata.reason == :normal
      assert metadata.status == :done
    end
  end

  describe "macrostep_start/4 and macrostep_stop/7" do
    # sabotage: `macrostep_start/4` hardcodes `trigger: :event` instead of
    # the given `trigger` -> red, `metadata.trigger == :cancel` fails -
    # reverted and confirmed green.
    test "start emits the trigger, event name, and span_ref - but no macrostep counter", %{
      ref: ref
    } do
      event = Event.external("go")
      span_ref = make_ref()

      assert :ok = Telemetry.macrostep_start("sess1", :cancel, event, span_ref)

      assert_received {[:statifier, :session, :macrostep, :start], ^ref, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
      assert metadata.trigger == :cancel
      assert metadata.event_name == "go"
      assert metadata.span_ref == span_ref
      refute Map.has_key?(metadata, :macrostep)
    end

    # sabotage: `macrostep_stop/7` computes `duration` as `start_time -
    # System.monotonic_time()` (operands swapped) -> red, `duration > 0`
    # fails since a real elapsed span is negated - reverted and confirmed
    # green.
    test "stop emits a positive duration, the outcome, and the same span_ref", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)
      start_time = System.monotonic_time() - 1_000_000
      span_ref = make_ref()

      assert :ok =
               Telemetry.macrostep_stop(
                 "sess1",
                 :event,
                 machine_state,
                 nil,
                 :quiescent,
                 start_time,
                 span_ref
               )

      assert_received {[:statifier, :session, :macrostep, :stop], ^ref, measurements, metadata}
      assert measurements.duration > 0
      assert measurements.macrostep == machine_state.macrostep
      assert measurements.microsteps == machine_state.microstep
      assert measurements.rounds == machine_state.round
      assert is_integer(measurements.monotonic_time)
      assert metadata.outcome == :quiescent
      assert metadata.event_name == nil
      assert metadata.span_ref == span_ref
    end
  end

  describe "interpret/3" do
    # sabotage: `interpret/3` emits `effect_count: 0` unconditionally -> red,
    # `measurements.effect_count == 3` fails - reverted and confirmed green.
    test "emits the injected effect count and step counters as measurements", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert :ok = Telemetry.interpret("sess1", 3, machine_state)

      assert_received {[:statifier, :session, :interpret], ^ref, measurements, metadata}
      assert measurements.effect_count == 3
      assert measurements.macrostep == machine_state.macrostep
      assert measurements.microstep == machine_state.microstep
      assert metadata == %{session_id: "sess1"}
    end
  end

  describe "effect/3 on the nine core kinds" do
    # sabotage: `core_shape/2`'s `Send` clause reports `microstep: 0`
    # unconditionally -> red, `measurements.microstep == payload.microstep`
    # fails for `:send` (payload's own `microstep` is `2`) - reverted and
    # confirmed green. Also verified for `round`: `core_shape/2`'s `Log`
    # clause changed to report `round: 0` unconditionally -> red,
    # `measurements.round == payload.round` fails for `:log` (payload's own
    # `round` is `1`) - reverted and confirmed green.
    test "emits the matching name, step counters, and the struct itself", %{ref: ref} do
      machine = located_machine()

      for {kind, payload} <- @core_fixtures do
        assert :ok = Telemetry.effect("sess1", machine, {kind, payload})

        assert_received {[:statifier, :session, :effect, ^kind], ^ref, measurements, metadata}
        assert measurements.macrostep == payload.macrostep
        assert measurements.microstep == payload.microstep
        assert measurements.round == payload.round
        assert metadata.effect == payload
        assert metadata.session_id == "sess1"
      end
    end

    # sabotage: `core_shape/2`'s `SendDelayed` clause drops `delay_ms` from
    # its measurements map -> red, `measurements.delay_ms` no longer exists
    # and the `KeyError` fails the assertion - reverted and confirmed green.
    test "puts delay_ms in measurements and send_id/target in metadata for :send_delayed", %{
      ref: ref
    } do
      machine = located_machine()

      payload = %SendDelayed{
        event: "e",
        delay_ms: 750,
        target: "#_parent",
        send_id: "sd1",
        c_index: nil,
        owner: nil,
        macrostep: 3,
        microstep: 4,
        round: 2
      }

      Telemetry.effect("sess1", machine, {:send_delayed, payload})

      assert_received {[:statifier, :session, :effect, :send_delayed], ^ref, measurements,
                       metadata}

      assert measurements.delay_ms == 750
      assert metadata.send_id == "sd1"
      assert metadata.target == "#_parent"
    end

    # sabotage: `core_shape/2`'s `BudgetExhausted` clause drops `round` from
    # its measurements map -> red, `measurements.round` no longer exists and
    # the `KeyError` fails the assertion - reverted and confirmed green.
    test "carries round in measurements for :budget_exhausted", %{ref: ref} do
      machine = located_machine()

      payload = %BudgetExhausted{
        configuration: MapSet.new(),
        budget: 12,
        pending_internal_events: [],
        macrostep: 9,
        microstep: 0,
        round: 12
      }

      Telemetry.effect("sess1", machine, {:budget_exhausted, payload})

      assert_received {[:statifier, :session, :effect, :budget_exhausted], ^ref, measurements,
                       _metadata}

      assert measurements.round == 12
    end

    # sabotage: `core_shape/2`'s `Done` clause drops `configuration` from its
    # metadata map -> red, `metadata.configuration` no longer exists and the
    # `KeyError` fails the assertion below - reverted and confirmed green.
    test "resolves :done's own configuration field to state ids (Fix 4)", %{ref: ref} do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")
      {:ok, b_index} = Machine.index(machine, "b")

      payload = %Done{
        configuration: MapSet.new([a_index, b_index]),
        macrostep: 1,
        microstep: 2,
        round: 1
      }

      Telemetry.effect("sess1", machine, {:done, payload})

      assert_received {[:statifier, :session, :effect, :done], ^ref, _measurements, metadata}
      assert metadata.configuration == MapSet.new(["a", "b"])
    end
  end

  describe "effect/3 on the nine trace kinds" do
    # sabotage: `trace_kind/1`'s `Trace.ExitSet` clause returns `:bogus`
    # instead of `:exit_set` -> red, no message arrives for
    # `[:statifier, :session, :trace, :exit_set]` (it now fires under
    # `[..., :bogus]`, which nothing asserts on but was still attached to,
    # so the assertion simply times out) - reverted and confirmed green.
    test "emits [:statifier, :session, :trace, kind] with the right kind", %{ref: ref} do
      machine = located_machine()

      for {kind, effect} <- @trace_fixtures do
        assert :ok = Telemetry.effect("sess1", machine, effect)
        assert_received {[:statifier, :session, :trace, ^kind], ^ref, _measurements, _metadata}
      end
    end

    # sabotage: `trace_shape/2`'s `Trace.Done` clause drops `configuration`
    # from its metadata map -> red, `metadata.configuration` no longer
    # exists and the `KeyError` fails the assertion below - reverted and
    # confirmed green.
    test "trace, :done also resolves its own configuration field to state ids (Fix 4)", %{
      ref: ref
    } do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      payload = %Trace.Done{
        configuration: MapSet.new([a_index]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Telemetry.effect("sess1", machine, {:trace, payload})

      assert_received {[:statifier, :session, :trace, :done], ^ref, _measurements, metadata}
      assert metadata.configuration == MapSet.new(["a"])
    end
  end

  describe "effect/3 location resolution" do
    # sabotage: `location/2`'s `c_index` clause resolves through
    # `Machine.at/2` (a state, not the content node) instead of
    # `Machine.content/2` -> red, `metadata.location ==
    # Machine.content(machine, 0).location` fails because the wrong node's
    # span comes back - reverted and confirmed green.
    #
    # No core effect in the current vocabulary carries a bare `t_index` -
    # only `Trace.TransitionsSelected.t_indexes`, a list, and no
    # list-carrying trace effect ever resolves a location (the singleton
    # carve-out is withdrawn - ADR-0040 Decision 4, amended). So
    # `location/2`'s own `t_index` clause has no reachable caller through
    # `effect/3`/`unroutable/3` today. It stays implemented per ADR-0040's
    # resolver contract (`Machine.transition/2` is one of the three named
    # readers) for whichever future effect names a bare `t_index`, and is
    # not exercised by a test for that reason.
    test "resolves location from c_index and from state_index against a real machine", %{
      ref: ref
    } do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      log_payload = %Log{
        label: "hi",
        c_index: 0,
        owner: {:onentry, a_index, 0},
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Telemetry.effect("sess1", machine, {:log, log_payload})

      assert_received {[:statifier, :session, :effect, :log], ^ref, _measurements, log_metadata}
      assert log_metadata.location == Machine.content(machine, 0).location

      invoke_payload = %Invoke{
        invoke_id: "i1",
        state_index: a_index,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Telemetry.effect("sess1", machine, {:invoke, invoke_payload})

      assert_received {[:statifier, :session, :effect, :invoke], ^ref, _measurements,
                       invoke_metadata}

      assert invoke_metadata.location == Machine.at(machine, a_index).location
    end

    # sabotage: `location/2`'s `%{c_index: nil} -> nil` clause is deleted,
    # so a `nil` `c_index` falls into the `Machine.content/2` clause instead
    # -> red, `Machine.content(machine, nil)` raises `ArithmeticError`
    # (`elem/2`'s tuple-index arithmetic on a `nil` index) rather than the
    # test receiving a `location: nil` message - reverted and confirmed
    # green.
    test "carries location: nil for an effect with no resolvable index", %{ref: ref} do
      machine = located_machine()
      payload = %Log{label: nil, c_index: nil, owner: nil, macrostep: 1, microstep: 1, round: 0}

      Telemetry.effect("sess1", machine, {:log, payload})

      assert_received {[:statifier, :session, :effect, :log], ^ref, _measurements, metadata}
      assert metadata.location == nil
    end

    # sabotage: the d_index location/2 clause is placed below the c_index
    # clauses -> a %DatamodelChange{} carrying both a d_index and a c_index:
    # nil matches `location(_machine, %{c_index: nil})` first and resolves to
    # `nil` instead of the <data> element's own location, reddening this
    # assertion.
    test "resolves location from a non-nil d_index through Machine.data/2", %{ref: ref} do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <datamodel>
                <data id="x" expr="1"/>
            </datamodel>
            <state id="a"/>
        </scxml>
        """)

      payload = %DatamodelChange{
        location_path: ["x"],
        location_source: "x",
        new_value: 1,
        prior_value: :undefined,
        d_index: 0,
        c_index: nil,
        owner: nil,
        macrostep: 1,
        microstep: 1
      }

      Telemetry.effect("sess1", machine, {:datamodel_change, payload})

      assert_received {[:statifier, :session, :effect, :datamodel_change], ^ref, _measurements,
                       metadata}

      assert metadata.location == Machine.data(machine, 0).location
    end

    # sabotage: `location/2`'s `d_index` clause's guard is dropped
    # (`when is_integer(d_index)`), so it becomes `defp location(machine,
    # %{d_index: d_index}), do: Machine.data(machine, d_index).location` and
    # matches *every* payload carrying a `d_index` field, `nil` included ->
    # a write's `d_index: nil` would call `Machine.data(machine, nil)` instead
    # of falling through to the `c_index` clause below, crashing rather than
    # resolving through `Machine.content/2` as this test expects.
    test "a write's d_index: nil still resolves location through Machine.content/2", %{ref: ref} do
      machine = located_machine()

      payload = %DatamodelChange{
        location_path: ["x"],
        location_source: "x",
        new_value: 1,
        prior_value: :undefined,
        d_index: nil,
        c_index: 0,
        owner: nil,
        macrostep: 1,
        microstep: 1
      }

      Telemetry.effect("sess1", machine, {:datamodel_change, payload})

      assert_received {[:statifier, :session, :effect, :datamodel_change], ^ref, _measurements,
                       metadata}

      assert metadata.location == Machine.content(machine, 0).location
    end

    # sabotage: `core_shape/2`'s `DatamodelInit` clause drops `datamodel` from
    # its metadata map (leaving `%{location: nil}`) -> red, `metadata.datamodel`
    # raises `KeyError` and the baseline never reaches a telemetry subscriber
    # at all, which is the whole point of the tag. Confirmed red and reverted.
    #
    # `:datamodel_init` is deliberately not in `@core_fixtures` above, for the
    # same reason `:datamodel_change` is not: that table's loop asserts a
    # uniform `(macrostep, microstep, effect)` shape, and both datamodel tags
    # carry a payload-specific metadata key that the uniform loop cannot see.
    # The generic contract is covered there; the specific key is covered here.
    test "the :datamodel_init baseline carries its starting map as metadata", %{ref: ref} do
      machine = located_machine()

      payload = %DatamodelInit{
        datamodel: %{"x" => :undefined, "_sessionid" => "sess1"},
        macrostep: 1,
        microstep: 1
      }

      Telemetry.effect("sess1", machine, {:datamodel_init, payload})

      assert_received {[:statifier, :session, :effect, :datamodel_init], ^ref, measurements,
                       metadata}

      assert metadata.datamodel == %{"x" => :undefined, "_sessionid" => "sess1"}
      assert metadata.effect == payload
      assert measurements.macrostep == 1
      assert measurements.microstep == 1

      # ADR-0040 makes `location` a key every core-family event carries. This
      # payload names no document node, so `core_shape/2` sets it as a literal
      # `nil` rather than calling `location/2` - asserted here alongside the
      # metadata above rather than in a test of its own, because a literal
      # cannot be broken by any `location/2` clause and a separate test would
      # be green by construction.
      assert metadata.location == nil
    end

    # sabotage: two mutations, each confirmed independently. (1)
    # `trace_shape/2`'s `Trace.ExitSet` clause omits `:size` from its
    # measurements map -> red, `measurements.size` no longer exists and the
    # `KeyError` fails the assertion - reverted and confirmed green. (2) the
    # same clause is reverted to its earlier `%{location: nil}` shape -> red,
    # `refute Map.has_key?(metadata, :location)` fails since the key
    # is present with a `nil` value - reverted and confirmed green.
    test "a list-carrying trace effect carries no location key, the index list, and a size measurement",
         %{ref: ref} do
      machine = located_machine()
      payload = %Trace.ExitSet{indexes: [1, 2, 3], macrostep: 1, microstep: 1, round: 0}

      Telemetry.effect("sess1", machine, {:trace, payload})

      assert_received {[:statifier, :session, :trace, :exit_set], ^ref, measurements, metadata}
      assert measurements.size == 3
      refute Map.has_key?(metadata, :location)
      assert metadata.effect.indexes == [1, 2, 3]
    end

    # sabotage: the withdrawn carve-out is reintroduced - `trace_shape/2`'s
    # `Trace.TransitionsSelected` singleton clause
    # (`%Trace.TransitionsSelected{t_indexes: [t_index]} -> %{location:
    # Machine.transition(machine, t_index).location}`) is reintroduced ahead
    # of the general list clause -> red, `refute Map.has_key?(one_metadata,
    # :location)` fails because the singleton case now carries a resolved
    # `location` again - reverted and confirmed green.
    test "Trace.TransitionsSelected carries no location key at any cardinality (singleton, empty, multi)",
         %{ref: ref} do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")
      [t_index] = Machine.at(machine, a_index).transitions

      one =
        {:trace,
         %Trace.TransitionsSelected{
           t_indexes: [t_index],
           event: Event.external("go"),
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, one)

      assert_received {[:statifier, :session, :trace, :transitions_selected], ^ref,
                       one_measurements, one_metadata}

      assert one_measurements.size == 1
      refute Map.has_key?(one_metadata, :location)

      zero =
        {:trace,
         %Trace.TransitionsSelected{
           t_indexes: [],
           event: nil,
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, zero)

      assert_received {[:statifier, :session, :trace, :transitions_selected], ^ref,
                       zero_measurements, zero_metadata}

      assert zero_measurements.size == 0
      refute Map.has_key?(zero_metadata, :location)

      many =
        {:trace,
         %Trace.TransitionsSelected{
           t_indexes: [t_index, t_index],
           event: Event.external("go"),
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, many)

      assert_received {[:statifier, :session, :trace, :transitions_selected], ^ref,
                       many_measurements, many_metadata}

      assert many_measurements.size == 2
      refute Map.has_key?(many_metadata, :location)
    end

    # sabotage: `trace_shape/2`'s `Trace.ExitSet` clause is changed to put
    # `location: List.first(indexes) && Machine.at(machine, List.first(indexes)).location`
    # into its metadata map -> red, `refute Map.has_key?(one_metadata,
    # :location)` fails for the singleton case (`indexes: [a_index]`) -
    # reverted and confirmed green.
    test "Trace.ExitSet carries no location key at any cardinality (singleton, empty, multi)", %{
      ref: ref
    } do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      one = {:trace, %Trace.ExitSet{indexes: [a_index], macrostep: 1, microstep: 1, round: 0}}
      Telemetry.effect("sess1", machine, one)

      assert_received {[:statifier, :session, :trace, :exit_set], ^ref, one_measurements,
                       one_metadata}

      assert one_measurements.size == 1
      refute Map.has_key?(one_metadata, :location)

      zero = {:trace, %Trace.ExitSet{indexes: [], macrostep: 1, microstep: 1, round: 0}}
      Telemetry.effect("sess1", machine, zero)

      assert_received {[:statifier, :session, :trace, :exit_set], ^ref, zero_measurements,
                       zero_metadata}

      assert zero_measurements.size == 0
      refute Map.has_key?(zero_metadata, :location)

      many =
        {:trace,
         %Trace.ExitSet{indexes: [a_index, a_index], macrostep: 1, microstep: 1, round: 0}}

      Telemetry.effect("sess1", machine, many)

      assert_received {[:statifier, :session, :trace, :exit_set], ^ref, many_measurements,
                       many_metadata}

      assert many_measurements.size == 2
      refute Map.has_key?(many_metadata, :location)
    end

    # sabotage: `trace_shape/2`'s `Trace.EntrySet` clause is changed to put
    # `location: List.first(indexes) && Machine.at(machine, List.first(indexes)).location`
    # into its metadata map -> red, `refute Map.has_key?(one_metadata,
    # :location)` fails for the singleton case - reverted and confirmed
    # green.
    test "Trace.EntrySet carries no location key at any cardinality (singleton, empty, multi)", %{
      ref: ref
    } do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      one = {:trace, %Trace.EntrySet{indexes: [a_index], macrostep: 1, microstep: 1, round: 0}}
      Telemetry.effect("sess1", machine, one)

      assert_received {[:statifier, :session, :trace, :entry_set], ^ref, one_measurements,
                       one_metadata}

      assert one_measurements.size == 1
      refute Map.has_key?(one_metadata, :location)

      zero = {:trace, %Trace.EntrySet{indexes: [], macrostep: 1, microstep: 1, round: 0}}
      Telemetry.effect("sess1", machine, zero)

      assert_received {[:statifier, :session, :trace, :entry_set], ^ref, zero_measurements,
                       zero_metadata}

      assert zero_measurements.size == 0
      refute Map.has_key?(zero_metadata, :location)

      many =
        {:trace,
         %Trace.EntrySet{indexes: [a_index, a_index], macrostep: 1, microstep: 1, round: 0}}

      Telemetry.effect("sess1", machine, many)

      assert_received {[:statifier, :session, :trace, :entry_set], ^ref, many_measurements,
                       many_metadata}

      assert many_measurements.size == 2
      refute Map.has_key?(many_metadata, :location)
    end

    # sabotage: `trace_shape/2`'s `Trace.ContentExecuted` clause is changed
    # to put `location: List.first(c_indexes) &&
    # Machine.content(machine, List.first(c_indexes)).location` into its
    # metadata map -> red, `refute Map.has_key?(one_metadata, :location)`
    # fails for the singleton case (`c_indexes: [0]`) - reverted and
    # confirmed green.
    test "Trace.ContentExecuted carries no location key at any cardinality (singleton, empty, multi)",
         %{ref: ref} do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")
      owner = {:onentry, a_index, 0}

      one =
        {:trace,
         %Trace.ContentExecuted{
           owner: owner,
           c_indexes: [0],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, one)

      assert_received {[:statifier, :session, :trace, :content_executed], ^ref, one_measurements,
                       one_metadata}

      assert one_measurements.size == 1
      refute Map.has_key?(one_metadata, :location)

      zero =
        {:trace,
         %Trace.ContentExecuted{owner: owner, c_indexes: [], macrostep: 1, microstep: 1, round: 0}}

      Telemetry.effect("sess1", machine, zero)

      assert_received {[:statifier, :session, :trace, :content_executed], ^ref, zero_measurements,
                       zero_metadata}

      assert zero_measurements.size == 0
      refute Map.has_key?(zero_metadata, :location)

      many =
        {:trace,
         %Trace.ContentExecuted{
           owner: owner,
           c_indexes: [0, 0],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, many)

      assert_received {[:statifier, :session, :trace, :content_executed], ^ref, many_measurements,
                       many_metadata}

      assert many_measurements.size == 2
      refute Map.has_key?(many_metadata, :location)
    end

    # sabotage: `trace_shape/2`'s `Trace.InvokePass` clause is changed to
    # put `location: List.first(state_indexes) &&
    # Machine.at(machine, List.first(state_indexes)).location` into its
    # metadata map -> red, `refute Map.has_key?(one_metadata, :location)`
    # fails for the singleton case - reverted and confirmed green.
    test "Trace.InvokePass carries no location key at any cardinality (singleton, empty, multi)",
         %{ref: ref} do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      one =
        {:trace,
         %Trace.InvokePass{
           state_indexes: [a_index],
           invoke_ids: ["i1"],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, one)

      assert_received {[:statifier, :session, :trace, :invoke_pass], ^ref, one_measurements,
                       one_metadata}

      assert one_measurements.size == 1
      refute Map.has_key?(one_metadata, :location)

      zero =
        {:trace,
         %Trace.InvokePass{
           state_indexes: [],
           invoke_ids: [],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, zero)

      assert_received {[:statifier, :session, :trace, :invoke_pass], ^ref, zero_measurements,
                       zero_metadata}

      assert zero_measurements.size == 0
      refute Map.has_key?(zero_metadata, :location)

      many =
        {:trace,
         %Trace.InvokePass{
           state_indexes: [a_index, a_index],
           invoke_ids: ["i1", "i2"],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}

      Telemetry.effect("sess1", machine, many)

      assert_received {[:statifier, :session, :trace, :invoke_pass], ^ref, many_measurements,
                       many_metadata}

      assert many_measurements.size == 2
      refute Map.has_key?(many_metadata, :location)
    end

    # sabotage: `trace_shape/2`'s `Trace.EventDequeued` clause is reverted to
    # `%{location: nil}` -> red, `refute Map.has_key?(metadata, :location)`
    # fails because the key is present (with a `nil` value, which
    # `Map.has_key?/2` still counts as present) - reverted and confirmed
    # green. `assert metadata.location == nil` would have passed on both the
    # fixed and the unfixed code, which is why this asserts key absence
    # instead.
    test "a trace effect that never resolves a location carries no location key at all", %{
      ref: ref
    } do
      machine = located_machine()

      payload = %Trace.EventDequeued{
        event: Event.external("e"),
        from: :external,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Telemetry.effect("sess1", machine, {:trace, payload})

      assert_received {[:statifier, :session, :trace, :event_dequeued], ^ref, _measurements,
                       metadata}

      refute Map.has_key?(metadata, :location)
    end
  end

  describe "unroutable/3" do
    # sabotage: `unroutable/3` drops `target`/`send_id` from its metadata
    # map -> red, `metadata.target` no longer exists and the `KeyError`
    # fails the assertion - reverted and confirmed green.
    test "emits target, send_id, and a resolved location", %{ref: ref} do
      machine = located_machine()
      {:ok, a_index} = Machine.index(machine, "a")

      payload = %Send{
        event: "e",
        target: "#_parent",
        send_id: "s1",
        c_index: 0,
        owner: {:onentry, a_index, 0},
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert :ok = Telemetry.unroutable("sess1", machine, {:send, payload})

      assert_received {[:statifier, :session, :unroutable], ^ref, measurements, metadata}
      assert measurements.macrostep == 1
      assert measurements.microstep == 1
      assert metadata.effect == payload
      assert metadata.target == "#_parent"
      assert metadata.send_id == "s1"
      assert metadata.location == Machine.content(machine, 0).location
    end
  end

  describe "measurements are numbers, for every event this module can emit" do
    # sabotage: `interpret/3`'s measurements map stringifies `effect_count`
    # (`%{effect_count: to_string(effect_count)}`) -> red, `is_number/1`
    # fails on the `[:statifier, :session, :interpret]` message's
    # `effect_count` value - reverted and confirmed green.
    test "every measurement value across every emitter is a number", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      Telemetry.init("sess1", machine, machine_state, nil)
      Telemetry.halt("sess1", :done, machine_state)
      Telemetry.terminate("sess1", :normal, :done, machine_state)
      span_ref = make_ref()
      Telemetry.macrostep_start("sess1", :event, Event.external("go"), span_ref)

      Telemetry.macrostep_stop(
        "sess1",
        :event,
        machine_state,
        nil,
        :quiescent,
        System.monotonic_time(),
        span_ref
      )

      Telemetry.interpret("sess1", 2, machine_state)

      for {kind, payload} <- @core_fixtures,
          do: Telemetry.effect("sess1", machine, {kind, payload})

      for {_kind, effect} <- @trace_fixtures, do: Telemetry.effect("sess1", machine, effect)

      Telemetry.unroutable(
        "sess1",
        machine,
        {:send, %Send{event: "e", c_index: nil, owner: nil, macrostep: 1, microstep: 1, round: 0}}
      )

      messages = drain(ref)
      assert messages != []

      for {_event, measurements, _metadata} <- messages do
        for {_key, value} <- measurements do
          assert is_number(value)
        end
      end
    end
  end

  # -- Phase 3: a live Statifier.Session wired to every emission seam -------

  describe "Statifier.Session wires the bridge into every emission seam" do
    # sabotage: `in_macrostep/4`'s `Telemetry.macrostep_stop(...)` call is
    # dropped -> red, the `[:statifier, :session, :macrostep, :stop]`
    # `assert_receive` below (`trigger: :initialize`) times out - reverted
    # and confirmed green.
    test "trace: false emits lifecycle and effect events, and no trace family", %{ref: ref} do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, trace: false)
      session_id = Session.session_id(session)

      assert_receive {[:statifier, :session, :init], ^ref, _measurements, init_metadata}
      assert init_metadata.session_id == session_id

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements,
                      %{trigger: :initialize}}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _measurements,
                      %{trigger: :initialize}}

      Session.send_event(session, "finish")

      assert_receive {[:statifier, :session, :effect, :done], ^ref, _measurements, _metadata}
      assert_receive {[:statifier, :session, :halt], ^ref, _measurements, %{reason: :done}}

      refute_receive {[:statifier, :session, :trace, _kind], ^ref, _measurements, _metadata}, 20
    end

    # sabotage: `perform_instruction({:notify, effect}, state, _override)`'s
    # `Telemetry.effect/3` call is dropped from the non-`Done` clause -> red,
    # `[:statifier, :session, :trace, :entry_set]` never arrives - reverted
    # and confirmed green.
    test "trace: true emits the same lifecycle events plus the trace family", %{ref: ref} do
      machine = compile!(two_state_doc())
      {:ok, _session} = Session.start_link(machine, trace: true)

      assert_receive {[:statifier, :session, :init], ^ref, _measurements, _metadata}

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements,
                      %{trigger: :initialize}}

      assert_receive {[:statifier, :session, :trace, :entry_set], ^ref, _measurements, _metadata}

      assert_receive {[:statifier, :session, :trace, :macrostep_stable], ^ref, _measurements,
                      _metadata}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _measurements,
                      %{trigger: :initialize}}
    end

    # sabotage: `in_macrostep/4` hardcodes `trigger: :initialize` regardless
    # of the caller's own `trigger` argument -> red, the `trigger: :event`
    # `assert_receive` calls below never match because every `macrostep,
    # :start`/`:stop` now reports `:initialize` - reverted and confirmed
    # green.
    test "the macrostep span fires once per accepted external event, trigger: :event", %{
      ref: ref
    } do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements,
                      %{trigger: :initialize}}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _measurements,
                      %{trigger: :initialize}}

      Session.send_event(session, "go")

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements,
                      %{trigger: :event, event_name: "go"}}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _measurements,
                      %{trigger: :event, event_name: "go"}}

      refute_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements, _metadata},
                     20
    end

    # sabotage: `drain_event/2` is changed to call `in_macrostep(state,
    # :initialize, event, fn ... end)` instead of `:event` -> red, sending a
    # second event pushes the count of `trigger: :initialize` `macrostep,
    # :start` messages to 2, reddening the `== 1` assertion below - reverted
    # and confirmed green.
    test "trigger: :initialize fires exactly once, at session start", %{ref: ref} do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      Session.send_event(session, "go")
      _status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)

      initialize_starts =
        ref
        |> drain()
        |> Enum.count(fn
          {[:statifier, :session, :macrostep, :start], _measurements, %{trigger: :initialize}} ->
            true

          _other ->
            false
        end)

      assert initialize_starts == 1
    end

    # sabotage: `drain_cancel/1` calls `in_macrostep(state, :event, nil, fn
    # ... end)` instead of `:cancel` -> red, the `trigger: :cancel`
    # `assert_receive` below never matches - reverted and confirmed green.
    test "trigger: :cancel fires on Session.cancel/1", %{ref: ref} do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      Session.cancel(session)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _measurements,
                      %{trigger: :cancel}}

      assert_receive {[:statifier, :session, :halt], ^ref, _measurements, %{reason: :cancelled}}
    end

    # sabotage: `macrostep_outcome/1`'s `defp macrostep_outcome(%State{halted:
    # reason}), do: reason` clause is replaced with `do: :quiescent`
    # unconditionally -> red, the `outcome: :budget_exhausted` assertion
    # below reddens (every stop event now reports `:quiescent`) - this is
    # Decision 2's own pinned case, the one `Trace.MacrostepStable` would
    # have missed. Reverted and confirmed green.
    test "a budget-exhausted machine emits outcome: :budget_exhausted on stop and halt", %{
      ref: ref
    } do
      machine = compile!(livelock_doc())
      {:ok, _session} = Session.start_link(machine, max_macrostep_rounds: 5)

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _measurements,
                      %{trigger: :initialize, outcome: :budget_exhausted}}

      assert_receive {[:statifier, :session, :halt], ^ref, _measurements,
                      %{reason: :budget_exhausted}}
    end

    # sabotage: `handle_cast({:interpret, effects}, state)`'s
    # `Telemetry.interpret/3` call is dropped -> red, the
    # `[:statifier, :session, :interpret]` `assert_receive` below times out -
    # reverted and confirmed green.
    test "Session.interpret/2 emits :interpret, and its injected effects are ordinary effect events (ADR-0029)",
         %{ref: ref} do
      machine = located_machine()
      {:ok, session} = Session.start_link(machine)

      assert_receive {[:statifier, :session, :effect, :log], ^ref, _measurements, core_metadata}

      injected = %Log{
        label: "injected",
        c_index: nil,
        owner: nil,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Session.interpret(session, [{:log, injected}])

      assert_receive {[:statifier, :session, :interpret], ^ref, measurements, _metadata}
      assert measurements.effect_count == 1

      assert_receive {[:statifier, :session, :effect, :log], ^ref, _measurements,
                      injected_metadata}

      assert injected_metadata.effect == injected
      # No key distinguishes the injected effect's metadata shape from the
      # core-derived one - ADR-0029's indistinguishability, restated at the
      # telemetry boundary.
      assert MapSet.new(Map.keys(injected_metadata)) == MapSet.new(Map.keys(core_metadata))
    end

    # sabotage: `terminate/2`'s `Telemetry.terminate/4` call is dropped ->
    # red, the `[:statifier, :session, :terminate]` `assert_receive` below
    # times out - reverted and confirmed green.
    test "[:statifier, :session, :terminate] fires on Session.stop/2", %{ref: ref} do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      Session.stop(session)

      assert_receive {[:statifier, :session, :terminate], ^ref, _measurements, %{reason: :normal}}
    end

    # sabotage: `perform_instruction({:notify, effect}, state, _override)`'s
    # `Telemetry.effect(state.session_id, state.machine_state.machine,
    # effect)` call has its `machine` argument replaced with `nil` -> red:
    # measurements/metadata are built eagerly at the call site whether or not
    # a handler is attached (this bridge's own "cost paid either way"
    # property), so `location/2` still calls
    # `Statifier.Machine.content(nil, 0)` and raises, crashing `init/1`
    # before `start_link/2` ever returns `{:ok, _}` even with the handler
    # detached below - reverted and confirmed green.
    test "a session with no telemetry handler attached still runs (the zero-handler path)", %{
      ref: ref
    } do
      :telemetry.detach(ref)

      machine = located_machine()
      assert {:ok, session} = Session.start_link(machine)
      assert Session.status(session).status == :running
    end

    # sabotage: `perform_instruction({:notify, effect}, state, _override)`
    # passes `state.machine_state` (a `%MachineState{}`) instead of
    # `state.machine_state.machine` (its `%Machine{}`) as `Telemetry.effect/3`'s
    # `machine` argument -> red, `Statifier.Machine.content/2` inside
    # `location/2` no longer receives a `%Machine{}`, so resolving the send
    # effect's location raises instead of returning one, and the
    # `assert_receive` below times out - reverted and confirmed green.
    test "a send from a state with a known source location carries a resolved location", %{
      ref: ref
    } do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry>
                    <send event="e" target="#_internal"/>
                </onentry>
            </state>
        </scxml>
        """)

      {:ok, _session} = Session.start_link(machine)

      assert_receive {[:statifier, :session, :effect, :send], ^ref, _measurements, metadata}
      assert %Statifier.Parser.Location{} = metadata.location
    end
  end

  # -- Fix 1: the start half never carries a counter it can disagree with --

  describe "macrostep_start/macrostep_stop pairing across all four triggers" do
    # sabotage: `macrostep_start/4`'s metadata map is given back
    # `macrostep: machine_state.macrostep` (the pre-fix shape) -> red, the
    # `refute Map.has_key?(..., :macrostep)` assertion below fails on the
    # `:event` trigger, whose start half - unlike `:initialize`'s - is
    # emitted before `MachineState.begin_macrostep/1` runs inside
    # `Interpreter.handle_event/2`, so the pre-fix value would have silently
    # disagreed with the stop half's post-increment one - reverted and
    # confirmed green.
    test "start never carries macrostep; stop's macrostep is always the authoritative value", %{
      ref: ref
    } do
      # :initialize - begin_macrostep/1 already ran before this span opens,
      # so its counter happens to agree even pre-fix; still asserted here so
      # a future regression on this trigger is caught too.
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :initialize} = init_start}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, init_stop_measurements,
                      %{trigger: :initialize}}

      refute Map.has_key?(init_start, :macrostep)
      assert init_stop_measurements.macrostep == 1

      # :event - the counter this span opens against advances *inside* the
      # core call it brackets (Interpreter.handle_event/2), the exact case
      # Fix 1 exists for.
      Session.send_event(session, "go")

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :event} = event_start}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, event_stop_measurements,
                      %{trigger: :event}}

      refute Map.has_key?(event_start, :macrostep)
      assert event_stop_measurements.macrostep == 2

      # :cancel - Interpreter.cancel/1 never calls begin_macrostep/1, so the
      # counter does not move, but the start half still carries none of it.
      machine2 = compile!(two_state_doc())
      {:ok, session2} = Session.start_link(machine2)
      drain(ref)

      Session.cancel(session2)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :cancel} = cancel_start}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, cancel_stop_measurements,
                      %{trigger: :cancel}}

      refute Map.has_key?(cancel_start, :macrostep)
      assert cancel_stop_measurements.macrostep == 1

      # :internal - ADR-0039 re-entry; Interpreter.deliver_internal/5 also
      # never calls begin_macrostep/1.
      machine3 = compile!(internal_send_doc())
      {:ok, _session3} = Session.start_link(machine3)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :initialize}}

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :internal} = internal_start}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, internal_stop_measurements,
                      %{trigger: :internal}}

      refute Map.has_key?(internal_start, :macrostep)
      assert internal_stop_measurements.macrostep == 1
    end
  end

  # -- Fix 2: span_ref pairs a span's halves and distinguishes nesting -----

  describe "span_ref correlation" do
    # sabotage: `in_macrostep/4` hoists `span_ref = make_ref()` out to a
    # module attribute computed once at compile time instead of calling
    # `make_ref/0` per invocation -> red, the nested `:internal` span's
    # `span_ref` equals the enclosing `:initialize` span's and the
    # `refute inner_ref == outer_ref` assertion below fails - reverted and
    # confirmed green.
    test "a nested :internal span carries a different span_ref than the :initialize span enclosing it",
         %{ref: ref} do
      machine = compile!(internal_send_doc())
      {:ok, _session} = Session.start_link(machine)

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :initialize, span_ref: outer_start_ref}}

      assert_receive {[:statifier, :session, :macrostep, :start], ^ref, _m,
                      %{trigger: :internal, span_ref: inner_ref}}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _m,
                      %{trigger: :internal, span_ref: ^inner_ref}}

      assert_receive {[:statifier, :session, :macrostep, :stop], ^ref, _m,
                      %{trigger: :initialize, span_ref: outer_stop_ref}}

      assert outer_stop_ref == outer_start_ref
      refute inner_ref == outer_start_ref
    end
  end

  # -- Fix 4: the terminal configuration is resolvable without a Machine ---

  describe "the terminal :done events resolve their own configuration" do
    # sabotage: `core_shape/2`'s `Done` clause is reverted to carry no
    # `configuration` key -> red, `metadata.configuration` no longer exists
    # on `[:statifier, :session, :effect, :done]` and the assertion below
    # raises a `KeyError` instead of matching - reverted and confirmed
    # green.
    test "effect, :done and trace, :done carry the reached final state's id, unlike halt's empty one",
         %{ref: ref} do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, trace: true)

      Session.send_event(session, "finish")

      assert_receive {[:statifier, :session, :effect, :done], ^ref, _m, done_metadata}
      assert done_metadata.configuration == MapSet.new(["fin"])

      assert_receive {[:statifier, :session, :trace, :done], ^ref, _m, trace_done_metadata}
      assert trace_done_metadata.configuration == MapSet.new(["fin"])

      # `MachineState.configuration` is already empty by the time `:halt`
      # fires (the chart exited every state to reach the final one) - the
      # contrast this fix exists to resolve around.
      assert_receive {[:statifier, :session, :halt], ^ref, _m, halt_metadata}
      assert halt_metadata.configuration == MapSet.new([])
    end
  end
end
