defmodule Statifier.Session.EffectsTest do
  use ExUnit.Case, async: true

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
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Session.Effects

  # `internal_event/1`'s own placeholder cause - round 0 is never read back
  # (`Statifier.Session.Effects.internal_event/1`'s own `@doc`), but has to
  # match exactly for these table-driven equality assertions.

  @session_id "sess_test"
  @origin SystemVariables.scxml_location(@session_id)
  @origintype SystemVariables.scxml_event_processor()

  # Table-driven over the whole `Effect.t()` vocabulary (eighteen tags: nine
  # core plus nine trace), mirroring `test/statifier/effect_test.exs`'s
  # shape - a vocabulary member with no matching clause here falls through to
  # `plan_one/1`'s lack of a catch-all and raises a `FunctionClauseError`
  # rather than silently planning nothing, so the table stays exhaustive.
  @vocabulary [
    {{:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}}},
       {:enqueue_event,
        Event.external("e",
          data: %{k: 1},
          origin: @origin,
          origintype: @origintype,
          sendid: nil
        )}
     ]},
    {{:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}},
     [
       {:notify, {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}},
       {:deliver, :internal,
        Event.internal("e", Cause.new({:content, nil, nil}, 1, 1, 0), data: nil, sendid: nil),
        {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}}
     ]},
    {{:send_delayed,
      %SendDelayed{
        event: "e",
        target: nil,
        data: %{k: 1},
        send_id: "s1",
        delay_ms: 30,
        macrostep: 1,
        microstep: 1
      }},
     [
       {:notify,
        {:send_delayed,
         %SendDelayed{
           event: "e",
           target: nil,
           data: %{k: 1},
           send_id: "s1",
           delay_ms: 30,
           macrostep: 1,
           microstep: 1
         }}},
       {:schedule, "s1", 30, :self,
        Event.external("e",
          data: %{k: 1},
          origin: @origin,
          origintype: @origintype,
          sendid: nil
        ),
        {:send_delayed,
         %SendDelayed{
           event: "e",
           target: nil,
           data: %{k: 1},
           send_id: "s1",
           delay_ms: 30,
           macrostep: 1,
           microstep: 1
         }}}
     ]},
    {{:send_delayed,
      %SendDelayed{
        event: "e",
        target: nil,
        send_id: nil,
        delay_ms: 30,
        macrostep: 1,
        microstep: 1
      }},
     [
       {:notify,
        {:send_delayed,
         %SendDelayed{
           event: "e",
           target: nil,
           send_id: nil,
           delay_ms: 30,
           macrostep: 1,
           microstep: 1
         }}},
       {:schedule, nil, 30, :self,
        Event.external("e", data: nil, origin: @origin, origintype: @origintype, sendid: nil),
        {:send_delayed,
         %SendDelayed{
           event: "e",
           target: nil,
           send_id: nil,
           delay_ms: 30,
           macrostep: 1,
           microstep: 1
         }}}
     ]},
    {{:send_delayed,
      %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:send_delayed,
         %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}}},
       {:schedule, nil, 30, :internal,
        Event.internal("e", Cause.new({:content, nil, nil}, 1, 1, 0), data: nil, sendid: nil),
        {:send_delayed,
         %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}}}
     ]},
    {{:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1}},
     [
       {:notify, {:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1}}},
       {:cancel_timers, "s1"}
     ]},
    {{:invoke,
      %Invoke{invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:invoke,
         %Invoke{invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1}}},
       {:start_child,
        %Invoke{invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1},
        {:invoke,
         %Invoke{invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1}}}
     ]},
    {{:cancel_invoke, %CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:cancel_invoke,
         %CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}}},
       {:stop_child, "i1"}
     ]},
    {{:autoforward,
      %Autoforward{
        invoke_id: "i1",
        state_index: 0,
        event: Event.external("e"),
        macrostep: 1,
        microstep: 1
      }},
     [
       {:notify,
        {:autoforward,
         %Autoforward{
           invoke_id: "i1",
           state_index: 0,
           event: Event.external("e"),
           macrostep: 1,
           microstep: 1
         }}},
       {:forward, "i1", Event.external("e")}
     ]},
    {{:done, %Done{configuration: MapSet.new([0]), macrostep: 1, microstep: 1}},
     [
       {:notify, {:done, %Done{configuration: MapSet.new([0]), macrostep: 1, microstep: 1}}},
       {:halt, :done}
     ]},
    {{:budget_exhausted,
      %BudgetExhausted{
        configuration: MapSet.new(),
        budget: 1,
        pending_internal_events: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }},
     [
       {:notify,
        {:budget_exhausted,
         %BudgetExhausted{
           configuration: MapSet.new(),
           budget: 1,
           pending_internal_events: [],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}},
       {:halt, :budget_exhausted}
     ]},
    {{:log, %Log{macrostep: 1, microstep: 1}},
     [{:notify, {:log, %Log{macrostep: 1, microstep: 1}}}]},
    {{:trace,
      %Trace.EventDequeued{event: nil, from: :external, macrostep: 1, microstep: 1, round: 0}},
     [
       {:notify,
        {:trace,
         %Trace.EventDequeued{event: nil, from: :external, macrostep: 1, microstep: 1, round: 0}}}
     ]},
    {{:trace, %Trace.TransitionsSelected{t_indexes: [], macrostep: 1, microstep: 1, round: 0}},
     [
       {:notify,
        {:trace, %Trace.TransitionsSelected{t_indexes: [], macrostep: 1, microstep: 1, round: 0}}}
     ]},
    {{:trace, %Trace.ExitSet{indexes: [], macrostep: 1, microstep: 1, round: 0}},
     [{:notify, {:trace, %Trace.ExitSet{indexes: [], macrostep: 1, microstep: 1, round: 0}}}]},
    {{:trace,
      %Trace.ContentExecuted{
        owner: {:transition, 0},
        c_indexes: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }},
     [
       {:notify,
        {:trace,
         %Trace.ContentExecuted{
           owner: {:transition, 0},
           c_indexes: [],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}}
     ]},
    {{:trace, %Trace.EntrySet{indexes: [], macrostep: 1, microstep: 1, round: 0}},
     [{:notify, {:trace, %Trace.EntrySet{indexes: [], macrostep: 1, microstep: 1, round: 0}}}]},
    {{:trace,
      %Trace.MacrostepStable{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}},
     [
       {:notify,
        {:trace,
         %Trace.MacrostepStable{
           configuration: MapSet.new(),
           macrostep: 1,
           microstep: 1,
           round: 0
         }}}
     ]},
    {{:trace, %Trace.Done{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}},
     [
       {:notify,
        {:trace, %Trace.Done{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}}}
     ]},
    {{:trace,
      %Trace.InvokePass{
        state_indexes: [],
        invoke_ids: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }},
     [
       {:notify,
        {:trace,
         %Trace.InvokePass{
           state_indexes: [],
           invoke_ids: [],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}}
     ]},
    {{:trace,
      %Trace.FinalizeAutoforward{
        event: Event.external("e"),
        finalized: [],
        forwarded: [],
        macrostep: 1,
        microstep: 1,
        round: 0
      }},
     [
       {:notify,
        {:trace,
         %Trace.FinalizeAutoforward{
           event: Event.external("e"),
           finalized: [],
           forwarded: [],
           macrostep: 1,
           microstep: 1,
           round: 0
         }}}
     ]}
  ]

  describe "plan/1 over the whole vocabulary" do
    # sabotage: n/a - this test only checks that the fixture table above is
    # complete, not any lib/ behavior.
    test "the table covers all twenty-one fixtures across the eighteen-tag vocabulary" do
      assert length(@vocabulary) == 21
    end

    for {{{tag, payload} = effect, expected}, index} <- Enum.with_index(@vocabulary) do
      # sabotage: `plan_one/1`'s `{:log, _}` clause is dropped -> the whole
      # `plan/1` call raises `FunctionClauseError` for the `:log` fixture, and
      # this test reddens instead of silently planning nothing for it.
      test "plans #{tag} carrying #{inspect(payload.__struct__)} (fixture #{index})" do
        assert Effects.plan([unquote(Macro.escape(effect))], @session_id) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "notify is emitted for every effect exactly once, in original order" do
    # sabotage: `plan_one/1`'s `:send` clause drops its own `{:notify, effect}`
    # element -> the assertion below on `:notify` count reddens
    test "a mixed list preserves order and emits one notify per effect" do
      log = {:log, %Log{macrostep: 1, microstep: 1}}
      send_effect = {:send, %Send{event: "e", target: nil, macrostep: 1, microstep: 1}}
      cancel = {:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1}}

      instructions = Effects.plan([log, send_effect, cancel], @session_id)

      notify_effects = for {:notify, e} <- instructions, do: e
      assert notify_effects == [log, send_effect, cancel]
    end
  end

  describe "a targeted send plans as a delivery, not an enqueue" do
    # sabotage: `plan_send/3`'s `:internal ->` clause is merged into the
    # `:self ->` clause (dropping the target check) -> a targeted send now
    # plans an `:enqueue_event` instruction instead of `:deliver`, and this
    # refute reddens
    test "no :enqueue_event instruction appears for a targeted send" do
      effect = {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}

      instructions = Effects.plan([effect], @session_id)

      refute Enum.any?(instructions, &match?({:enqueue_event, _}, &1))
      assert Enum.any?(instructions, &match?({:deliver, :internal, _event, ^effect}, &1))
    end
  end

  describe "data is carried onto the enqueued event" do
    # sabotage: the enqueue clause uses `Event.external(send.event)` (dropping
    # the `data:` option) -> the enqueued event's `data` field is `nil`
    # instead of the fixture's payload, and this assertion reddens
    test "the enqueued event's data matches the send effect's data" do
      effect = {:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}}

      assert [_notify, {:enqueue_event, %Event{data: %{k: 1}}}] =
               Effects.plan([effect], @session_id)
    end
  end

  describe "a send_id: nil delayed send still schedules" do
    # sabotage: the `:send_delayed` clause guards on `not is_nil(send.send_id)`
    # in addition to `target: nil` -> a `send_id: nil` delayed send falls
    # through to `FunctionClauseError` instead of planning a `:schedule`
    # instruction, and this assertion reddens
    test "plans a :schedule instruction with send_id nil" do
      effect =
        {:send_delayed,
         %SendDelayed{
           event: "e",
           target: nil,
           send_id: nil,
           delay_ms: 30,
           macrostep: 1,
           microstep: 1
         }}

      assert [_notify, {:schedule, nil, 30, :self, %Event{name: "e"}, ^effect}] =
               Effects.plan([effect], @session_id)
    end
  end

  describe "an unsupported <invoke type> raises error.execution instead of :unroutable" do
    # sabotage: `plan_invoke/2`'s `else` branch drops the `invoke_index` from
    # the raised origin, hardcoding `0` -> this assertion reddens for a
    # non-zero `invoke_index` fixture
    test "plans {:raise, :platform, \"error.execution\", {:invoke, state_index, invoke_index}, []}" do
      effect =
        {:invoke,
         %Invoke{
           invoke_id: "i1",
           type: "http://example.com/BasicHTTPEventProcessor",
           state_index: 2,
           invoke_index: 3,
           macrostep: 1,
           microstep: 1
         }}

      assert [_notify, {:raise, :platform, "error.execution", {:invoke, 2, 3}, []}] =
               Effects.plan([effect], @session_id)
    end

    # sabotage: `plan_invoke/2`'s `if Target.supported_invoke_type?(...)` is
    # inverted to `unless` -> a supported (`nil`) invoke type would raise
    # instead of planning `{:start_child, ...}`, and this refute reddens
    test "no :raise instruction appears for a supported (nil) invoke type" do
      effect =
        {:invoke,
         %Invoke{
           invoke_id: "i1",
           type: nil,
           state_index: 0,
           invoke_index: 0,
           macrostep: 1,
           microstep: 1
         }}

      instructions = Effects.plan([effect], @session_id)

      refute Enum.any?(instructions, &match?({:raise, _, _, _, _}, &1))
      assert Enum.any?(instructions, &match?({:start_child, _invoke, ^effect}, &1))
    end
  end
end
