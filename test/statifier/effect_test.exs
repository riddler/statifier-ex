defmodule Statifier.EffectTest do
  use ExUnit.Case, async: true

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
  alias Statifier.{Event, MachineState}

  require Statifier.Effect, as: Effect

  # `Effect.trace/3`'s gate reads only `.trace`, and `Trace.*.new/2` reads
  # only the counters - a placeholder `:machine` is enough here.
  defp ms(macrostep, microstep, trace) do
    %MachineState{machine: :placeholder, macrostep: macrostep, microstep: microstep, trace: trace}
  end

  describe "trace?/1" do
    @core_effects [
      {:send, %Send{event: "e", macrostep: 1, microstep: 1, round: 0}},
      {:send_delayed,
       %SendDelayed{event: "e", delay_ms: 100, macrostep: 1, microstep: 1, round: 0}},
      {:cancel, %Cancel{send_id: "s1", macrostep: 1, microstep: 1, round: 0}},
      {:invoke,
       %Invoke{
         invoke_id: "i1",
         state_index: 0,
         invoke_index: 0,
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:cancel_invoke,
       %CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1, round: 0}},
      {:autoforward,
       %Autoforward{
         invoke_id: "i1",
         state_index: 0,
         event: Event.external("e"),
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:budget_exhausted,
       %BudgetExhausted{
         configuration: MapSet.new(),
         budget: 1,
         pending_internal_events: [],
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:done, %Done{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}},
      {:log, %Log{macrostep: 1, microstep: 1, round: 0}},
      {:datamodel_change,
       %DatamodelChange{
         location_path: ["x"],
         location_source: "x",
         new_value: 1,
         prior_value: :undefined,
         d_index: 0,
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:datamodel_init,
       %DatamodelInit{
         datamodel: %{"_sessionid" => "sess_1"},
         macrostep: 1,
         microstep: 1,
         round: 0
       }}
    ]

    @trace_effects [
      {:trace,
       %Trace.EventDequeued{
         event: nil,
         from: :external,
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:trace, %Trace.TransitionsSelected{t_indexes: [], macrostep: 1, microstep: 1, round: 0}},
      {:trace, %Trace.ExitSet{indexes: [], macrostep: 1, microstep: 1, round: 0}},
      {:trace,
       %Trace.ContentExecuted{
         owner: {:transition, 0},
         c_indexes: [],
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:trace, %Trace.EntrySet{indexes: [], macrostep: 1, microstep: 1, round: 0}},
      {:trace,
       %Trace.MacrostepStable{
         configuration: MapSet.new(),
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:trace, %Trace.Done{configuration: MapSet.new(), macrostep: 1, microstep: 1, round: 0}},
      {:trace,
       %Trace.InvokePass{
         state_indexes: [],
         invoke_ids: [],
         macrostep: 1,
         microstep: 1,
         round: 0
       }},
      {:trace,
       %Trace.FinalizeAutoforward{
         event: Event.external("e"),
         finalized: [],
         forwarded: [],
         macrostep: 1,
         microstep: 1,
         round: 0
       }}
    ]

    # sabotage: `trace?/1` returns `true` unconditionally (dropping the
    # second, catch-all clause) -> every core-effect case below reddens.
    for {tag, payload} <- @core_effects do
      test "#{tag} is not a trace effect" do
        refute Effect.trace?({unquote(tag), unquote(Macro.escape(payload))})
      end
    end

    # sabotage: `trace?/1`'s first clause matches on the payload's struct
    # module instead of the `:trace` tag (so `{:log, %Trace.Done{}}` would
    # slip past too) -- for the actual vocabulary this is exercised by the
    # `:trace` tag no longer matching at all, reddening every case below.
    for {tag, payload} <- @trace_effects do
      test "#{tag} carrying #{inspect(payload.__struct__)} is a trace effect" do
        assert Effect.trace?({unquote(tag), unquote(Macro.escape(payload))})
      end
    end

    # sabotage: n/a - this test only checks that the fixture tables above
    # are complete, not any lib/ behavior.
    test "the table covers all twenty effects" do
      assert length(@core_effects) + length(@trace_effects) == 20
    end
  end

  describe "owner field on the three send-family effects" do
    # sabotage: `Effect.Send`'s `defstruct` entry is changed from `:owner`
    # to `owner: :bogus` -> this reddens, since a `%Send{}` built with no
    # `:owner` key would default to `:bogus` instead of `nil`.
    test "Send defaults owner to nil and accepts one" do
      assert %Send{event: "e", macrostep: 1, microstep: 1, round: 0}.owner == nil

      assert %Send{event: "e", macrostep: 1, microstep: 1, round: 0, owner: {:transition, 0}}.owner ==
               {:transition, 0}
    end

    # sabotage: `Effect.SendDelayed`'s `defstruct` entry is changed from
    # `:owner` to `owner: :bogus` -> this reddens, since a `%SendDelayed{}`
    # built with no `:owner` key would default to `:bogus` instead of `nil`.
    test "SendDelayed defaults owner to nil and accepts one" do
      assert %SendDelayed{event: "e", delay_ms: 1, macrostep: 1, microstep: 1, round: 0}.owner ==
               nil

      assert %SendDelayed{
               event: "e",
               delay_ms: 1,
               macrostep: 1,
               microstep: 1,
               round: 0,
               owner: {:onentry, 0, 0}
             }.owner == {:onentry, 0, 0}
    end

    # sabotage: `Effect.Cancel`'s `defstruct` entry is changed from `:owner`
    # to `owner: :bogus` -> this reddens, since a `%Cancel{}` built with no
    # `:owner` key would default to `:bogus` instead of `nil`.
    test "Cancel defaults owner to nil and accepts one" do
      assert %Cancel{send_id: "s1", macrostep: 1, microstep: 1, round: 0}.owner == nil

      assert %Cancel{send_id: "s1", macrostep: 1, microstep: 1, round: 0, owner: {:onexit, 0, 0}}.owner ==
               {:onexit, 0, 0}
    end
  end

  describe "trace/3 gate" do
    # sabotage: `Effect.trace/3` checks `not machine_state.trace` (inverting
    # the condition) -> the on-case below returns `[]` instead of the
    # one-element list, reddening this assertion.
    test "gate on: returns a one-element list holding the stamped payload" do
      effects = Effect.trace(ms(2, 3, true), Trace.EntrySet, indexes: [1, 2])

      assert [{:trace, %Trace.EntrySet{indexes: [1, 2], macrostep: 2, microstep: 3}}] = effects
    end

    # sabotage: `Effect.trace/3`'s `else` branch returns `[nil]` instead of
    # `[]` -> this assertion reddens.
    test "gate off: returns an empty list" do
      assert Effect.trace(ms(2, 3, false), Trace.EntrySet, indexes: [1, 2]) == []
    end

    # sabotage: `Effect.trace/3` builds the payload before the `if` (moving
    # `unquote(payload_module).new(...)` above the `if machine_state.trace
    # do`) -> the `fields` expression's `send/2` fires even when trace is
    # off, and this test's `refute_received` reddens.
    test "laziness: the fields expression is never evaluated when trace is off" do
      Effect.trace(ms(1, 1, false), Trace.EntrySet, indexes: send(self(), :evaluated) && [1])

      refute_received :evaluated
    end

    # Companion to the laziness test above: proves the `send/2` in `fields`
    # is reachable at all, so the laziness test cannot pass merely because
    # the expression was unreachable for an unrelated reason.
    #
    # sabotage: `Effect.trace/3` checks `not machine_state.trace` (inverting
    # the condition) -> trace-on now takes the `else` branch, `fields` is
    # never evaluated, and `assert_received` below reddens.
    test "the fields expression is evaluated when trace is on" do
      Effect.trace(ms(1, 1, true), Trace.EntrySet, indexes: send(self(), :evaluated) && [1])

      assert_received :evaluated
    end

    # sabotage: `Effect.trace/3` writes `unquote(machine_state).trace`
    # directly in the `if` (instead of binding `machine_state =
    # unquote(machine_state)` first and reading that), so the argument
    # expression evaluates twice - once for the `if` check, once again as
    # `new/2`'s argument -> the second `refute_received` below reddens
    # because a second `:evaluated` message has arrived.
    test "single-evaluation: machine_state is evaluated exactly once when trace is on" do
      effects =
        Effect.trace(
          send(self(), :evaluated) && ms(1, 1, true),
          Trace.EntrySet,
          indexes: [1]
        )

      assert [{:trace, %Trace.EntrySet{}}] = effects
      assert_received :evaluated
      refute_received :evaluated
    end

    # Single evaluation must hold on this path too, independent of the
    # laziness property - the previous test's mutation only doubles the
    # evaluation on the branch that calls `new/2`, so it does not redden
    # this one; this test needs its own mutation.
    #
    # sabotage: `Effect.trace/3` evaluates `machine_state` a second,
    # discarded time before the real binding (`_ = unquote(machine_state);
    # machine_state = unquote(machine_state)`) -> a second `:evaluated`
    # message arrives regardless of the trace flag, reddening this
    # assertion.
    test "single-evaluation: machine_state is evaluated exactly once when trace is off" do
      effects =
        Effect.trace(
          send(self(), :evaluated) && ms(1, 1, false),
          Trace.EntrySet,
          indexes: [1]
        )

      assert effects == []
      assert_received :evaluated
      refute_received :evaluated
    end
  end
end
