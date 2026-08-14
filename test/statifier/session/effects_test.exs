defmodule Statifier.Session.EffectsTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Session.Effects

  # Table-driven over the whole `Effect.t()` vocabulary (fourteen tags: seven
  # core plus seven trace), mirroring `test/statifier/effect_test.exs`'s
  # shape - a vocabulary member with no matching clause here falls through to
  # `plan_one/1`'s lack of a catch-all and raises a `FunctionClauseError`
  # rather than silently planning nothing, so the table stays exhaustive.
  @vocabulary [
    {{:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}}},
       {:enqueue_event, Event.external("e", data: %{k: 1})}
     ]},
    {{:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}},
     [
       {:notify, {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}},
       {:unroutable, {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}}
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
       {:schedule, "s1", 30, Event.external("e", data: %{k: 1})}
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
       {:schedule, nil, 30, Event.external("e")}
     ]},
    {{:send_delayed,
      %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}},
     [
       {:notify,
        {:send_delayed,
         %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}}},
       {:unroutable,
        {:send_delayed,
         %SendDelayed{event: "e", target: "#_internal", delay_ms: 30, macrostep: 1, microstep: 1}}}
     ]},
    {{:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1}},
     [
       {:notify, {:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1}}},
       {:cancel_timers, "s1"}
     ]},
    {{:invoke, %Invoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}},
     [
       {:notify, {:invoke, %Invoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}}},
       {:unroutable,
        {:invoke, %Invoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}}}
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
     ]}
  ]

  describe "plan/1 over the whole vocabulary" do
    # sabotage: n/a - this test only checks that the fixture table above is
    # complete, not any lib/ behavior.
    test "the table covers all seventeen fixtures across the fourteen-tag vocabulary" do
      assert length(@vocabulary) == 17
    end

    for {{{tag, payload} = effect, expected}, index} <- Enum.with_index(@vocabulary) do
      # sabotage: `plan_one/1`'s `{:log, _}` clause is dropped -> the whole
      # `plan/1` call raises `FunctionClauseError` for the `:log` fixture, and
      # this test reddens instead of silently planning nothing for it.
      test "plans #{tag} carrying #{inspect(payload.__struct__)} (fixture #{index})" do
        assert Effects.plan([unquote(Macro.escape(effect))]) == unquote(Macro.escape(expected))
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

      instructions = Effects.plan([log, send_effect, cancel])

      notify_effects = for {:notify, e} <- instructions, do: e
      assert notify_effects == [log, send_effect, cancel]
    end
  end

  describe "a targeted send plans as unroutable, not an enqueue" do
    # sabotage: the `{:send, %Send{target: _}}` clause is merged into the
    # `target: nil` clause (dropping the `target: nil` guard) -> a targeted
    # send now plans an `:enqueue_event` instruction, and this refute reddens
    test "no :enqueue_event instruction appears for a targeted send" do
      effect = {:send, %Send{event: "e", target: "#_internal", macrostep: 1, microstep: 1}}

      instructions = Effects.plan([effect])

      refute Enum.any?(instructions, &match?({:enqueue_event, _}, &1))
      assert Enum.any?(instructions, &match?({:unroutable, ^effect}, &1))
    end
  end

  describe "data is carried onto the enqueued event" do
    # sabotage: the enqueue clause uses `Event.external(send.event)` (dropping
    # the `data:` option) -> the enqueued event's `data` field is `nil`
    # instead of the fixture's payload, and this assertion reddens
    test "the enqueued event's data matches the send effect's data" do
      effect = {:send, %Send{event: "e", target: nil, data: %{k: 1}, macrostep: 1, microstep: 1}}

      assert [_notify, {:enqueue_event, %Event{data: %{k: 1}}}] = Effects.plan([effect])
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

      assert [_notify, {:schedule, nil, 30, %Event{name: "e"}}] = Effects.plan([effect])
    end
  end
end
