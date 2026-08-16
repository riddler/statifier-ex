defmodule Statifier.Session.TelemetryTest do
  use ExUnit.Case, async: false

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Machine
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

  @core_fixtures [
    {:send,
     %Send{
       event: "e",
       target: "#_parent",
       send_id: "s1",
       c_index: nil,
       owner: nil,
       macrostep: 1,
       microstep: 2
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
       microstep: 2
     }},
    {:cancel, %Cancel{send_id: "s3", c_index: nil, owner: nil, macrostep: 1, microstep: 2}},
    {:invoke,
     %Invoke{invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 2}},
    {:cancel_invoke, %CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 2}},
    {:autoforward,
     %Autoforward{
       invoke_id: "i1",
       state_index: 0,
       event: Event.external("e"),
       macrostep: 1,
       microstep: 2
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
    {:done, %Done{configuration: MapSet.new(), macrostep: 1, microstep: 2}},
    {:log, %Log{label: "l", c_index: nil, owner: nil, macrostep: 1, microstep: 2}}
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
    # sabotage: `@effect_kinds` drops `:log` -> red, `length(events) == 25`
    # fails (24 names) - reverted and confirmed green.
    test "returns exactly 25 names, all `[:statifier, :session | _]`" do
      events = Telemetry.events()

      assert length(events) == 25
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

  describe "macrostep_start/4 and macrostep_stop/6" do
    # sabotage: `macrostep_start/4` hardcodes `trigger: :event` instead of
    # the given `trigger` -> red, `metadata.trigger == :cancel` fails -
    # reverted and confirmed green.
    test "start emits the trigger, macrostep and event name", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)
      event = Event.external("go")

      assert :ok = Telemetry.macrostep_start("sess1", :cancel, machine_state, event)

      assert_received {[:statifier, :session, :macrostep, :start], ^ref, measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.trigger == :cancel
      assert metadata.macrostep == machine_state.macrostep
      assert metadata.event_name == "go"
    end

    # sabotage: `macrostep_stop/6` computes `duration` as `start_time -
    # System.monotonic_time()` (operands swapped) -> red, `duration > 0`
    # fails since a real elapsed span is negated - reverted and confirmed
    # green.
    test "stop emits a positive duration and the outcome", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)
      start_time = System.monotonic_time() - 1_000_000

      assert :ok =
               Telemetry.macrostep_stop(
                 "sess1",
                 :event,
                 machine_state,
                 nil,
                 :quiescent,
                 start_time
               )

      assert_received {[:statifier, :session, :macrostep, :stop], ^ref, measurements, metadata}
      assert measurements.duration > 0
      assert measurements.macrostep == machine_state.macrostep
      assert measurements.microsteps == machine_state.microstep
      assert measurements.rounds == machine_state.round
      assert metadata.outcome == :quiescent
      assert metadata.event_name == nil
    end
  end

  describe "interpret/3" do
    # sabotage: `interpret/3` emits `effect_count: 0` unconditionally -> red,
    # `measurements.effect_count == 3` fails - reverted and confirmed green.
    test "emits the injected effect count", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert :ok = Telemetry.interpret("sess1", 3, machine_state)

      assert_received {[:statifier, :session, :interpret], ^ref, measurements, metadata}
      assert measurements.effect_count == 3
      assert metadata.macrostep == machine_state.macrostep
      assert metadata.microstep == machine_state.microstep
    end
  end

  describe "effect/3 on the nine core kinds" do
    # sabotage: `core_shape/2`'s `Send` clause reports `microstep: 0`
    # unconditionally -> red, `measurements.microstep == payload.microstep`
    # fails for `:send` (payload's own `microstep` is `2`) - reverted and
    # confirmed green.
    test "emits the matching name, step counters, and the struct itself", %{ref: ref} do
      machine = located_machine()

      for {kind, payload} <- @core_fixtures do
        assert :ok = Telemetry.effect("sess1", machine, {kind, payload})

        assert_received {[:statifier, :session, :effect, ^kind], ^ref, measurements, metadata}
        assert measurements.macrostep == payload.macrostep
        assert measurements.microstep == payload.microstep
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
        microstep: 4
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
  end

  describe "effect/3 location resolution" do
    # sabotage: `location/2`'s `c_index` clause resolves through
    # `Machine.at/2` (a state, not the content node) instead of
    # `Machine.content/2` -> red, `metadata.location ==
    # Machine.content(machine, 0).location` fails because the wrong node's
    # span comes back - reverted and confirmed green.
    #
    # No core effect in the current vocabulary carries a bare `t_index` -
    # only `Trace.TransitionsSelected.t_indexes`, a list, which Decision 4
    # excludes from resolution - so `location/2`'s `t_index` clause has no
    # reachable caller through `effect/3`/`unroutable/3` today. It stays
    # implemented per ADR-0040's resolver contract (`Machine.transition/2`
    # is one of the three named readers) for whichever future effect names
    # a `t_index`, and is not exercised by a test for that reason.
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
        microstep: 1
      }

      Telemetry.effect("sess1", machine, {:log, log_payload})

      assert_received {[:statifier, :session, :effect, :log], ^ref, _measurements, log_metadata}
      assert log_metadata.location == Machine.content(machine, 0).location

      invoke_payload = %Invoke{
        invoke_id: "i1",
        state_index: a_index,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1
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
      payload = %Log{label: nil, c_index: nil, owner: nil, macrostep: 1, microstep: 1}

      Telemetry.effect("sess1", machine, {:log, payload})

      assert_received {[:statifier, :session, :effect, :log], ^ref, _measurements, metadata}
      assert metadata.location == nil
    end

    # sabotage: `trace_shape/1`'s `Trace.ExitSet` clause omits `:size` from
    # its measurements map -> red, `measurements.size` no longer exists and
    # the `KeyError` fails the assertion - reverted and confirmed green.
    test "a list-carrying trace effect carries location: nil, the index list, and a size measurement",
         %{ref: ref} do
      machine = located_machine()
      payload = %Trace.ExitSet{indexes: [1, 2, 3], macrostep: 1, microstep: 1, round: 0}

      Telemetry.effect("sess1", machine, {:trace, payload})

      assert_received {[:statifier, :session, :trace, :exit_set], ^ref, measurements, metadata}
      assert measurements.size == 3
      assert metadata.location == nil
      assert metadata.effect.indexes == [1, 2, 3]
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
        microstep: 1
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
      Telemetry.macrostep_start("sess1", :event, machine_state, Event.external("go"))

      Telemetry.macrostep_stop(
        "sess1",
        :event,
        machine_state,
        nil,
        :quiescent,
        System.monotonic_time()
      )

      Telemetry.interpret("sess1", 2, machine_state)

      for {kind, payload} <- @core_fixtures,
          do: Telemetry.effect("sess1", machine, {kind, payload})

      for {_kind, effect} <- @trace_fixtures, do: Telemetry.effect("sess1", machine, effect)

      Telemetry.unroutable(
        "sess1",
        machine,
        {:send, %Send{event: "e", c_index: nil, owner: nil, macrostep: 1, microstep: 1}}
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
end
