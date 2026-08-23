defmodule Statifier.TelemetryTest do
  use ExUnit.Case, async: false

  alias Statifier.Effect.{
    Autoforward,
    BudgetExhausted,
    Cancel,
    CancelInvoke,
    Done,
    Invoke,
    Log,
    Send,
    SendDelayed,
    Trace
  }

  alias Statifier.{Event, Machine, Telemetry}
  alias Statifier.Session.Telemetry, as: SessionTelemetry

  # Handlers are global to the VM (`:telemetry.attach_many/4` registers on a
  # shared name), so this file is `async: false` - mirroring
  # test/statifier/session/telemetry_test.exs's own setup, since both files
  # would otherwise deliver into each other's mailboxes when run concurrently.
  setup do
    ref = :telemetry_test.attach_event_handlers(self(), Telemetry.events())
    on_exit(fn -> :telemetry.detach(ref) end)
    {:ok, ref: ref}
  end

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

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

  # Copied from test/statifier/session/telemetry_test.exs's own
  # @core_fixtures/@trace_fixtures - module attributes do not cross files -
  # so the two lists stay recognizably the same list.
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
       round: 1,
       ordinal: 1
     }},
    {:cancel,
     %Cancel{
       send_id: "s3",
       c_index: nil,
       owner: nil,
       macrostep: 1,
       microstep: 2,
       round: 1,
       ordinal: 2
     }},
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
    {:exit_set,
     {:trace,
      %Trace.ExitSet{
        indexes: [],
        configuration: MapSet.new(),
        macrostep: 1,
        microstep: 1,
        round: 0
      }}},
    {:content_executed,
     {:trace,
      %Trace.ContentExecuted{
        owner: {:transition, 0},
        c_indexes: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }}},
    {:entry_set,
     {:trace,
      %Trace.EntrySet{
        indexes: [],
        configuration: MapSet.new(),
        macrostep: 1,
        microstep: 1,
        round: 0
      }}},
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
    # reverted and confirmed green. Moved from
    # test/statifier/session/telemetry_test.exs:279-295, retargeted at
    # Statifier.Telemetry because the moduledoc moved with the body.
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

  describe "driver is a real parameter, not a constant" do
    # sabotage: `init/6`'s metadata map hardcodes `driver: :session` instead
    # of the given `driver` -> red, `metadata.driver == :test_driver` fails
    # for `[:statifier, :session, :init]` - reverted and confirmed green.
    #
    # Drives every one of the 27 events `Telemetry.events/0` names with the
    # non-`:session` atom `:test_driver` - the seven lifecycle calls, then
    # every core/trace fixture through `effect/4`, then `unroutable/4` -
    # drains the mailbox, and asserts every drained message carries
    # `driver: :test_driver`. Modelled on
    # test/statifier/session/telemetry_test.exs's own "measurements are
    # numbers, for every event this module can emit" describe, which drives
    # every emitter once the same way.
    test "every one of the 27 events carries the given driver in metadata", %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)
      driver = :test_driver

      Telemetry.init(driver, "sess1", machine, machine_state, nil, false)
      Telemetry.halt(driver, "sess1", :done, machine_state)
      Telemetry.terminate(driver, "sess1", :normal, :done, machine_state)
      span_ref = make_ref()
      Telemetry.macrostep_start(driver, "sess1", :event, Event.external("go"), span_ref)

      Telemetry.macrostep_stop(
        driver,
        "sess1",
        :event,
        machine_state,
        nil,
        :quiescent,
        System.monotonic_time(),
        span_ref
      )

      Telemetry.interpret(driver, "sess1", 2, machine_state)

      for {kind, payload} <- @core_fixtures,
          do: Telemetry.effect(driver, "sess1", machine, {kind, payload})

      for {_kind, effect} <- @trace_fixtures,
          do: Telemetry.effect(driver, "sess1", machine, effect)

      Telemetry.unroutable(
        driver,
        "sess1",
        machine,
        {:send, %Send{event: "e", c_index: nil, owner: nil, macrostep: 1, microstep: 1, round: 0}}
      )

      messages = drain(ref)
      assert messages != []

      for {_event, _measurements, metadata} <- messages do
        assert metadata.driver == :test_driver
      end
    end
  end

  describe "unroutable/4" do
    # sabotage: `unroutable/4`'s metadata map hardcodes `driver: :session`
    # instead of the given `driver` -> red, `metadata.driver ==
    # :test_driver` fails - reverted and confirmed green. `unroutable/4` is
    # the one lifecycle emitter that both threads `driver` and resolves
    # `location`.
    test "carries driver and still resolves location", %{ref: ref} do
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

      assert :ok = Telemetry.unroutable(:test_driver, "sess1", machine, {:send, payload})

      assert_received {[:statifier, :session, :unroutable], ^ref, _measurements, metadata}
      assert metadata.driver == :test_driver
      assert metadata.location == Machine.content(machine, 0).location
    end
  end

  describe "equivalence with the Statifier.Session.Telemetry facade" do
    # sabotage: `Statifier.Session.Telemetry.halt/3` is changed to call
    # `Telemetry.halt(:not_session, ...)` instead of pinning `:session` ->
    # red, `facade_metadata == direct_metadata` fails since the facade's
    # `driver` no longer matches the value pinned by calling
    # `Telemetry.halt/4` directly with `:session` - reverted and confirmed
    # green.
    #
    # One representative event from each family: a lifecycle event
    # (`halt`), a core effect (`:log`), and a trace effect
    # (`:event_dequeued`). Proves "byte-for-byte identical for Session
    # consumers except the additive key" mechanically rather than by
    # inspection.
    test "calling the facade and calling Telemetry directly with :session produce identical events",
         %{ref: ref} do
      machine = located_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      SessionTelemetry.halt("sess1", :done, machine_state)
      assert_receive {[:statifier, :session, :halt], ^ref, facade_measurements, facade_metadata}

      Telemetry.halt(:session, "sess1", :done, machine_state)
      assert_receive {[:statifier, :session, :halt], ^ref, direct_measurements, direct_metadata}

      assert facade_measurements == direct_measurements
      assert facade_metadata == direct_metadata

      log_payload = %Log{
        label: "l",
        c_index: nil,
        owner: nil,
        macrostep: 1,
        microstep: 2,
        round: 1
      }

      SessionTelemetry.effect("sess1", machine, {:log, log_payload})

      assert_receive {[:statifier, :session, :effect, :log], ^ref, facade_log_measurements,
                      facade_log_metadata}

      Telemetry.effect(:session, "sess1", machine, {:log, log_payload})

      assert_receive {[:statifier, :session, :effect, :log], ^ref, direct_log_measurements,
                      direct_log_metadata}

      assert facade_log_measurements == direct_log_measurements
      assert facade_log_metadata == direct_log_metadata

      trace_payload = %Trace.EventDequeued{
        event: Event.external("e"),
        from: :external,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      SessionTelemetry.effect("sess1", machine, {:trace, trace_payload})

      assert_receive {[:statifier, :session, :trace, :event_dequeued], ^ref,
                      facade_trace_measurements, facade_trace_metadata}

      Telemetry.effect(:session, "sess1", machine, {:trace, trace_payload})

      assert_receive {[:statifier, :session, :trace, :event_dequeued], ^ref,
                      direct_trace_measurements, direct_trace_metadata}

      assert facade_trace_measurements == direct_trace_measurements
      assert facade_trace_metadata == direct_trace_metadata
    end
  end

  describe "Statifier.Session.Telemetry.events/0 stays in bijection with Statifier.Telemetry.events/0" do
    # sabotage: `SessionTelemetry.events/0`'s `defdelegate` target is changed
    # to a hand-copied literal list missing one name -> red, `length ==
    # length(Telemetry.events())` fails - reverted and confirmed green.
    test "both return 27 names and are the same list" do
      assert length(SessionTelemetry.events()) == 27
      assert length(SessionTelemetry.events()) == length(Telemetry.events())
      assert SessionTelemetry.events() == Telemetry.events()
    end
  end
end
