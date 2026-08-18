defmodule Statifier.Effect.TraceTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Trace.{ContentExecuted, Done, EntrySet}
  alias Statifier.Effect.Trace.{EventDequeued, ExitSet, FinalizeAutoforward}
  alias Statifier.Effect.Trace.{InvokePass, MacrostepStable, TransitionsSelected}
  alias Statifier.{Event, MachineState}

  # `new/2` never inspects `:machine` - a placeholder is enough for every
  # payload module under test here, which only reads the counters. Each
  # call site below uses three distinct values so a mis-wired merge (a
  # swapped key, a hardcoded field) cannot pass by coincidence.
  defp ms(macrostep, microstep, round) do
    %MachineState{machine: :placeholder, macrostep: macrostep, microstep: microstep, round: round}
  end

  describe "EventDequeued.new/2" do
    # sabotage: `EventDequeued.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      event = Event.external("go")

      payload = EventDequeued.new(ms(3, 2, 8), event: event, from: :external)

      assert %EventDequeued{event: ^event, from: :external, macrostep: 3, microstep: 2, round: 8} =
               payload
    end
  end

  describe "TransitionsSelected.new/2" do
    # sabotage: `TransitionsSelected.new/2` hardcodes `macrostep: 0,
    # microstep: 0, round: 0` instead of reading them off `machine_state` ->
    # this assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      event = Event.external("go")

      payload = TransitionsSelected.new(ms(5, 1, 9), t_indexes: [1, 2], event: event)

      assert %TransitionsSelected{
               t_indexes: [1, 2],
               event: ^event,
               macrostep: 5,
               microstep: 1,
               round: 9
             } = payload
    end

    # sabotage: `TransitionsSelected.new/2` requires `:event` to be present
    # (removing its default `nil` from the struct) -> this eventless-round
    # call raises instead of defaulting, reddening the test.
    test "event defaults to nil for an eventless round" do
      payload = TransitionsSelected.new(ms(1, 1, 1), t_indexes: [])

      assert payload.event == nil
    end
  end

  describe "ExitSet.new/2" do
    # sabotage: `ExitSet.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      configuration = MapSet.new([2, 4])

      payload = ExitSet.new(ms(2, 4, 6), indexes: [9, 3, 1], configuration: configuration)

      assert %ExitSet{
               indexes: [9, 3, 1],
               configuration: ^configuration,
               macrostep: 2,
               microstep: 4,
               round: 6
             } = payload
    end
  end

  describe "ContentExecuted.new/2" do
    # sabotage: `ContentExecuted.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      payload = ContentExecuted.new(ms(4, 1, 7), owner: {:onentry, 3, 0}, c_indexes: [7, 8])

      assert %ContentExecuted{owner: {:onentry, 3, 0}, c_indexes: [7, 8], macrostep: 4} = payload
      assert payload.microstep == 1
      assert payload.round == 7
    end
  end

  describe "EntrySet.new/2" do
    # sabotage: `EntrySet.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      configuration = MapSet.new([1, 2])

      payload = EntrySet.new(ms(6, 3, 10), indexes: [1, 2, 5], configuration: configuration)

      assert %EntrySet{
               indexes: [1, 2, 5],
               configuration: ^configuration,
               macrostep: 6,
               microstep: 3,
               round: 10
             } = payload
    end
  end

  describe "MacrostepStable.new/2" do
    # sabotage: `MacrostepStable.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      configuration = MapSet.new([1, 2, 3])

      payload = MacrostepStable.new(ms(7, 2, 11), configuration: configuration)

      assert %MacrostepStable{
               configuration: ^configuration,
               macrostep: 7,
               microstep: 2,
               round: 11
             } =
               payload
    end
  end

  describe "InvokePass.new/2" do
    # sabotage: `InvokePass.new/2` hardcodes `macrostep: 0, microstep: 0,
    # round: 0` instead of reading them off `machine_state` -> this
    # assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      payload = InvokePass.new(ms(4, 2, 6), state_indexes: [1, 3], invoke_ids: ["inv_1"])

      assert %InvokePass{
               state_indexes: [1, 3],
               invoke_ids: ["inv_1"],
               macrostep: 4,
               microstep: 2,
               round: 6
             } = payload
    end
  end

  describe "FinalizeAutoforward.new/2" do
    # sabotage: `FinalizeAutoforward.new/2` hardcodes `macrostep: 0,
    # microstep: 0, round: 0` instead of reading them off `machine_state` ->
    # this assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      event = Event.external("go", invokeid: "inv-a")

      payload =
        FinalizeAutoforward.new(ms(3, 5, 2),
          event: event,
          finalized: ["inv-a"],
          forwarded: ["inv-a"]
        )

      assert %FinalizeAutoforward{
               event: ^event,
               finalized: ["inv-a"],
               forwarded: ["inv-a"],
               macrostep: 3,
               microstep: 5,
               round: 2
             } = payload
    end
  end

  describe "Done.new/2" do
    # sabotage: `Done.new/2` swaps `donedata` and `configuration` in the
    # struct it returns -> this assertion reddens.
    test "stamps counters from machine_state and sets its own fields" do
      configuration = MapSet.new([1])

      payload = Done.new(ms(9, 5, 12), donedata: %{"x" => 1}, configuration: configuration)

      assert %Done{
               donedata: %{"x" => 1},
               configuration: ^configuration,
               macrostep: 9,
               microstep: 5,
               round: 12
             } = payload
    end

    # sabotage: `Done.new/2` requires `:donedata` to be present (removing its
    # default `nil` from the struct) -> a top-level final with no
    # `<donedata>` raises instead of defaulting, reddening the test.
    test "donedata defaults to nil" do
      payload = Done.new(ms(1, 1, 1), configuration: MapSet.new())

      assert payload.donedata == nil
    end
  end
end
