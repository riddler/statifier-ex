defmodule Statifier.Interpreter.MicrostepTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order.
  #
  #  0 scxml (root)
  #  1   a                  -- onexit log; transition event="go" -> b w/ content log
  #  2   b                  -- onentry log
  #  3   eventless_holder   -- eventless transition (no event attr) -> eventless_target w/ content log
  #  4   eventless_target
  #  5   internal_holder    -- transition event="fire" -> internal_target
  #  6   internal_target
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onexit>
              <log label="a-exit"/>
          </onexit>
          <transition event="go" target="b">
              <log label="t-content"/>
          </transition>
      </state>
      <state id="b">
          <onentry>
              <log label="b-enter"/>
          </onentry>
      </state>
      <state id="eventless_holder">
          <transition target="eventless_target">
              <log label="eventless-content"/>
          </transition>
      </state>
      <state id="eventless_target"/>
      <state id="internal_holder">
          <transition event="fire" target="internal_target"/>
      </state>
      <state id="internal_target"/>
  </scxml>
  """

  @indexes %{
    a: 1,
    b: 2,
    eventless_holder: 3,
    eventless_target: 4,
    internal_holder: 5,
    internal_target: 6
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration, opts \\ [trace: true]) do
    %{MachineState.new(machine, opts) | configuration: MapSet.new(configuration)}
  end

  # Every transition here has a distinct `event` attribute purely as a
  # lookup key (mirrors selection_acceptance_test.exs's own helper), except
  # the eventless transition, found by its empty `events` list instead.
  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  defp eventless_transition(machine) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == []))
  end

  defp trace_effects(effects), do: Enum.filter(effects, &Effect.trace?/1)

  describe "microstep/2" do
    # sabotage: `microstep/2` in lib/statifier/interpreter.ex has its
    # `execute_transition_content/2` call deleted, leaving
    # `exit_effects ++ enter_effects` -> "t-content" disappears from the
    # effect list, reddening the label-order assertion below.
    test "exits, runs the transition's content, and enters, in that order" do
      m = machine()
      go = transition_named(m, "go")
      ms = machine_state(m, [idx(:a)], trace: false)

      {_ms, effects} = Interpreter.microstep(ms, [go])

      assert [
               {:log, %{label: "a-exit"}},
               {:log, %{label: "t-content"}},
               {:log, %{label: "b-enter"}}
             ] = effects
    end
  end

  describe "microstep/1" do
    # sabotage: `run_selected/3`'s `MachineState.begin_microstep/1` call is
    # deleted -> `microstep` stays `0`, reddening the counter assertion.
    test "with an eventless transition enabled runs it and advances microstep by one" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_holder)])

      assert {result, _effects} = Interpreter.microstep(ms)
      assert result.microstep == ms.microstep + 1
      assert MapSet.member?(result.configuration, idx(:eventless_target))
      refute MapSet.member?(result.configuration, idx(:eventless_holder))
    end

    # sabotage: `internal_round/1` is changed to peek the queue instead of
    # dequeuing (`:queue.peek/1` in place of `MachineState.dequeue_internal/1`,
    # leaving the event on the queue) -> `internal_events(result) == []`
    # reddens because the event is still there.
    test "with no eventless transition and one internal event dequeues it, selects on it, and runs the resulting set" do
      m = machine()

      ms =
        m
        |> machine_state([idx(:internal_holder)])
        |> MachineState.raise_internal("fire", {:state, idx(:internal_holder)})

      assert {result, _effects} = Interpreter.microstep(ms)
      assert MachineState.internal_events(result) == []
      assert MapSet.member?(result.configuration, idx(:internal_target))
      assert result.microstep == ms.microstep + 1
    end

    # sabotage: `run_selected/3`'s `case transitions do [] -> ...` branch is
    # changed to always call `MachineState.begin_microstep/1` regardless of
    # whether `transitions` is empty -> `microstep` advances even though
    # nothing was enabled, reddening the "unchanged" assertion.
    test "with an internal event enabling nothing consumes the event, leaves microstep unchanged, and traces the dequeue" do
      m = machine()

      ms =
        m
        |> machine_state([idx(:internal_holder)])
        |> MachineState.raise_internal("no-such-event", {:state, idx(:internal_holder)})

      assert {result, effects} = Interpreter.microstep(ms)
      assert MachineState.internal_events(result) == []
      assert result.microstep == ms.microstep

      assert Enum.find(effects, fn
               {:trace, %Effect.Trace.EventDequeued{event: %{name: "no-such-event"}} = payload} ->
                 payload.from == :internal and payload.macrostep == ms.macrostep and
                   payload.microstep == ms.microstep

               _other ->
                 false
             end)
    end

    # sabotage: `internal_round/1`'s `:empty` clause is changed to
    # `{machine_state, probe_effects}` (dropping the `:quiescent` tag) ->
    # the return shape no longer matches, reddening the pattern match below.
    test "on an empty queue with nothing eventless reports quiescence, carrying its own position" do
      m = machine()
      ms = machine_state(m, [idx(:internal_target)])

      assert {:quiescent, result, _effects} = Interpreter.microstep(ms)
      assert result.configuration == ms.configuration
      assert MachineState.internal_events(result) == []
      assert {result.macrostep, result.microstep} == {ms.macrostep, ms.microstep}
    end

    # sabotage: `internal_round/1`'s `:empty` clause has its
    # `run_selected(machine_state, [], nil)` call deleted, returning
    # `{:quiescent, machine_state, []}` -> the terminal probe stops emitting
    # `TransitionsSelected`, reddening the assertion below.
    test "the terminal eventless probe still emits TransitionsSelected with t_indexes: []" do
      m = machine()
      ms = machine_state(m, [idx(:internal_target)], trace: true)

      assert {:quiescent, _result, effects} = Interpreter.microstep(ms)

      assert [%Effect.Trace.TransitionsSelected{t_indexes: [], event: nil}] =
               for({:trace, %Effect.Trace.TransitionsSelected{} = p} <- effects, do: p)
    end

    # sabotage: the `def microstep(%MachineState{running: false} =
    # machine_state), do: {:quiescent, machine_state, []}` clause is deleted,
    # falling through to the general clause -> a stopped machine_state is
    # (wrongly) run through selection instead of short-circuiting, reddening
    # the pattern match below. Also verified as a sabotage of the
    # `running: false` clause's own `MachineState.begin_round/1` call: with
    # it removed, `round` stays unadvanced and the equality reddens the same
    # way.
    test "on running: false reports quiescence with no effects" do
      m = machine()
      ms = %{machine_state(m, [idx(:eventless_holder)]) | running: false}

      assert {:quiescent, %{ms | round: ms.round + 1}, []} == Interpreter.microstep(ms)
    end

    # sabotage: `begin_round/1`'s call is deleted from the general clause's
    # head -> `round` stays at its starting value instead of advancing by
    # one, reddening the equality assertion.
    test "one call advances round by exactly one" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_holder)])

      assert {result, _effects} = Interpreter.microstep(ms)
      assert result.round == ms.round + 1
    end

    # sabotage: `begin_round/1`'s call is deleted from the `running: false`
    # clause -> the exhausted position's own round stays unadvanced on the
    # next hand-stepped call, reddening the equality assertion.
    test "a non-running machine_state's :quiescent return also advances round" do
      m = machine()
      ms = %{machine_state(m, [idx(:eventless_holder)]) | running: false, round: 5}

      assert {:quiescent, result, []} = Interpreter.microstep(ms)
      assert result.round == 6
    end

    # Decision 2 (revised): quiescence carries the machine_state that
    # `Selection.select_eventless_transitions/1` returned, not the one
    # `microstep/1` was handed. Selection returns it unchanged today
    # (selection_test.exs pins that), so no runtime assertion can currently
    # tell the two apart - this pins the source shape instead, the same way
    # "the machine_state Selection returns is threaded" below does.
    #
    # The write this protects is a non-queue one. An `error.execution`
    # enqueue rescues itself: it leaves the internal queue non-empty, so
    # `internal_round/1` takes its dequeue branch rather than the terminal
    # one. A datamodel write or a memo has no such luck, and under the old
    # bare-`:quiescent` shape the fold dropped it with nothing going red.
    #
    # sabotage: `macrostep/3`'s quiescent clause is changed to
    # `{:quiescent, _ms, round_effects} -> {:quiescent, machine_state,
    # effects ++ round_effects, rounds_left}`, falling back to the parameter
    # instead of the returned position -> the source no longer contains the
    # rebind, reddening the `=~` assertion.
    test "the quiescent round's machine_state is carried out, not discarded" do
      source = File.read!(Path.join(File.cwd!(), "lib/statifier/interpreter.ex"))

      assert source =~ "{machine_state, probe_effects} = run_selected(machine_state, [], nil)\n"
      assert source =~ "{:quiescent, machine_state, probe_effects}"

      assert source =~
               "{:quiescent, machine_state, round_effects} ->\n" <>
                 "        {:quiescent, machine_state, effects ++ round_effects, rounds_left}"
    end

    # sabotage: `run_selected/3`'s `Enum.map(transitions, & &1.t_index)` is
    # changed to `[]` unconditionally -> `t_indexes` no longer names the
    # eventless transition, reddening the equality assertion.
    test "TransitionsSelected carries t_indexes and the matched event; the eventless round carries event: nil" do
      m = machine()
      eventless = eventless_transition(m)
      ms = machine_state(m, [idx(:eventless_holder)])

      {_result, effects} = Interpreter.microstep(ms)

      assert [%Effect.Trace.TransitionsSelected{t_indexes: t_indexes, event: nil}] =
               for(
                 {:trace, %Effect.Trace.TransitionsSelected{} = payload} <- effects,
                 do: payload
               )

      assert t_indexes == [eventless.t_index]
    end

    # Decision 2's non-terminal case: the eventless probe comes back empty,
    # but the internal queue still has an event, so both selection sites
    # trace - one with `t_indexes: []` for the probe, one with the actual
    # dequeued event's selection.
    #
    # sabotage: `internal_round/1`'s `run_selected(machine_state, [], nil)`
    # call for the eventless probe is deleted, leaving only the dequeued
    # event's selection -> only one `TransitionsSelected` shows up, reddening
    # the count assertion.
    test "an eventless probe that comes back empty while the queue is non-empty still emits a TransitionsSelected with t_indexes: []" do
      m = machine()

      ms =
        m
        |> machine_state([idx(:internal_holder)])
        |> MachineState.raise_internal("fire", {:state, idx(:internal_holder)})

      {_result, effects} = Interpreter.microstep(ms)

      selected =
        for {:trace, %Effect.Trace.TransitionsSelected{} = payload} <- effects, do: payload

      assert length(selected) == 2
      assert Enum.any?(selected, &(&1.t_indexes == [] and &1.event == nil))
      assert Enum.any?(selected, &(&1.t_indexes != [] and &1.event != nil))
    end

    # sabotage: `execute_transition_content/2` is deleted from `microstep/2`'s
    # body (dropping the `content_effects` term entirely) -> the
    # "eventless-content" log disappears, reddening the `Enum.any?/2`
    # assertion below.
    test "with trace: false, a round that runs content still returns the :log effect and zero trace effects" do
      m = machine()
      ms = machine_state(m, [idx(:eventless_holder)], trace: false)

      {_result, effects} = Interpreter.microstep(ms)

      assert Enum.any?(effects, &match?({:log, %{label: "eventless-content"}}, &1))
      assert trace_effects(effects) == []
    end

    # Decision 13: `Selection.select_eventless_transitions/1` and
    # `Selection.select_transitions/2` both return their input machine_state
    # unchanged today (selection_test.exs's own "the machine_state comes
    # back unchanged" pins), so no runtime assertion here can currently
    # distinguish "threaded" from "discarded and reused" - both produce an
    # identical result. This pins the source shape instead, so the day
    # either call's rebind is dropped, this test - not silent behavior -
    # catches it.
    #
    # sabotage: `{machine_state, eventless_transitions} =
    # Selection.select_eventless_transitions(machine_state)` is changed to
    # `{_ms, eventless_transitions} = Selection.select_eventless_transitions(machine_state)`,
    # discarding the returned position and reusing the outer binding instead
    # -> the source no longer contains the rebind pattern, reddening the
    # `=~` assertion.
    test "the machine_state Selection returns is threaded, not discarded" do
      source = File.read!(Path.join(File.cwd!(), "lib/statifier/interpreter.ex"))

      assert source =~
               "{machine_state, eventless_transitions} = Selection.select_eventless_transitions(machine_state)"

      assert source =~
               "{machine_state, transitions} = Selection.select_transitions(machine_state, event)"
    end
  end
end
