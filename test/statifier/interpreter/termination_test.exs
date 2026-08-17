defmodule Statifier.Interpreter.TerminationTest do
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
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order.
  #
  #  0 scxml (root)
  #  1   start           -- onexit log; eventless transition -> done
  #  2   stable          -- no transitions, no content: quiescent forever
  #  3   parent          -- compound; onexit log
  #  4     leaf          -- onexit log
  #  5     h             -- history, shallow, default -> leaf
  #  6   done            -- top-level <final>; static donedata "42" -> 42
  #  7   done_nil        -- top-level <final>; no <donedata>
  #  8   done_compiled   -- top-level <final>; donedata expr="1 + 1", evaluates to 2
  #  9   done_compiled_fail -- top-level <final>; donedata expr fails to evaluate
  # 10   done_param      -- top-level <final>; donedata <param name="Var" expr="1 + 1"/>
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="start">
      <state id="start">
          <onexit>
              <log label="start-exit"/>
          </onexit>
          <transition target="done"/>
      </state>
      <state id="stable"/>
      <state id="parent">
          <onexit>
              <log label="parent-exit"/>
          </onexit>
          <state id="leaf">
              <onexit>
                  <log label="leaf-exit"/>
              </onexit>
          </state>
          <history id="h" type="shallow">
              <transition target="leaf"/>
          </history>
      </state>
      <final id="done">
          <donedata>
              <content>42</content>
          </donedata>
      </final>
      <final id="done_nil"/>
      <final id="done_compiled">
          <donedata>
              <content expr="1 + 1"/>
          </donedata>
      </final>
      <final id="done_compiled_fail">
          <donedata>
              <content expr="undeclared_var"/>
          </donedata>
      </final>
      <final id="done_param">
          <donedata>
              <param name="Var" expr="1 + 1"/>
          </donedata>
      </final>
  </scxml>
  """

  @indexes %{
    start: 1,
    stable: 2,
    parent: 3,
    leaf: 4,
    h: 5,
    done: 6,
    done_nil: 7,
    done_compiled: 8,
    done_compiled_fail: 9,
    done_param: 10
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration, opts \\ [trace: true]) do
    %{MachineState.new(machine, opts) | configuration: MapSet.new(configuration)}
  end

  defp trace_effects(effects), do: Enum.filter(effects, &Effect.trace?/1)

  defp log_labels(effects) do
    for {:log, %Effect.Log{label: label}} <- effects, do: label
  end

  describe "main_event_loop/1 - a document whose only transition targets a top-level final" do
    # AC: "exit_interpreter ports the pseudocode; terminal {:done, donedata}
    # emitted exactly once; static donedata only"
    #
    # sabotage: `exit_interpreter/1`'s per-state `ms = %{ms | configuration:
    # MapSet.delete(ms.configuration, state_index)}` line is deleted, so the
    # exit walk runs onexit blocks but never removes states from the
    # configuration -> the "configuration is empty" assertion below reddens.
    test "running goes false, status becomes :done, configuration empties" do
      m = machine()
      ms = machine_state(m, [idx(:start)])

      {result, _effects} = Interpreter.main_event_loop(ms)

      refute result.running
      assert result.status == :done
      assert result.configuration == MapSet.new()
    end

    # sabotage: `exit_interpreter/1`'s terminal effect list is built as
    # `[done_effect] ++ exit_effects ++ done_trace` instead of
    # `exit_effects ++ done_trace ++ [done_effect]` -> `{:done, _}` is no
    # longer the last member, reddening the assertion below.
    test "the {:done, _} effect appears exactly once and is the last member" do
      m = machine()
      ms = machine_state(m, [idx(:start)])

      {_result, effects} = Interpreter.main_event_loop(ms)

      done_effects = for {:done, _payload} = effect <- effects, do: effect
      assert [done_effect] = done_effects
      assert List.last(effects) == done_effect
    end
  end

  describe "exit_interpreter/1 - round" do
    # sabotage: `exit_interpreter/1`'s `%Effect.Done{}` literal is changed
    # from `round: machine_state.round` to `round: 0` -> reddens against
    # this fixture, whose `machine_state.round` is set to a nonzero value
    # before the call. Confirmed red and reverted.
    test "the done effect's round matches the machine state's round it was stamped from" do
      m = machine()
      ms = %{machine_state(m, [idx(:done)]) | round: 3}

      {_result, effects} = Interpreter.exit_interpreter(ms)

      assert {:done, %Effect.Done{round: 3}} = List.last(effects)
    end
  end

  describe "exit_interpreter/1 - donedata" do
    # sabotage: `exit_interpreter/1`'s `ExitEntry.donedata(ms, state_index)`
    # call is replaced with `{ms, :undefined}` -> the static `42` and
    # evaluated `2` cases below both redden while the already-`:undefined`
    # `done_nil` case stays green, pointing at exactly the wiring this
    # mutation broke.
    test "static and evaluated donedata ride the terminal effect; absent donedata is :undefined" do
      m = machine()

      {static_result, static_effects} =
        Interpreter.exit_interpreter(machine_state(m, [idx(:done)]))

      assert {:done, %Effect.Done{donedata: 42}} = List.last(static_effects)
      assert static_result.status == :done

      {_result, absent_effects} = Interpreter.exit_interpreter(machine_state(m, [idx(:done_nil)]))
      assert {:done, %Effect.Done{donedata: :undefined}} = List.last(absent_effects)

      {_result, compiled_effects} =
        Interpreter.exit_interpreter(machine_state(m, [idx(:done_compiled)]))

      assert {:done, %Effect.Done{donedata: 2}} = List.last(compiled_effects)
    end

    # AC: "a failing top-level <content expr> donedata leaves Effect.Done's
    # donedata :undefined, plus one error.execution visible on the returned
    # terminal MachineState" (Decision 8 of
    # docs/plans/260813-st-af3.7-log-donedata-param-event-data-coercion.md
    # - the error is enqueued on the internal queue but never dequeued,
    # since the event loop has already stopped by the time
    # exit_interpreter/1 runs; that is Appendix D's own consequence, not a
    # deviation). The failure produced no data, not a null value
    # (`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`, W3C
    # test528).
    #
    # sabotage: `evaluate_donedata/3`'s `{:error, reason}` clause is
    # changed to skip the `MachineState.raise_platform/4` call -> the
    # `error.execution` would never be enqueued, reddening the
    # `internal_events/1` assertion below while `Effect.Done`'s `donedata`
    # stays `:undefined` regardless (a false-green risk this sabotage rules
    # out).
    test "a failing top-level <content expr> donedata leaves donedata :undefined and enqueues one error.execution" do
      m = machine()

      {result, effects} =
        Interpreter.exit_interpreter(machine_state(m, [idx(:done_compiled_fail)]))

      assert {:done, %Effect.Done{donedata: :undefined}} = List.last(effects)
      assert [event] = MachineState.internal_events(result)
      assert event.name == "error.execution"
    end

    # AC: "the same param map reaches Effect.Done / Trace.Done at a
    # top-level final, and the two agree" - `exit_interpreter/1` calls
    # `ExitEntry.donedata/2` exactly once and threads the same value into
    # both `Effect.Done.donedata` and `Trace.Done.donedata`
    # (`docs/plans/260813-st-af3.7-log-donedata-param-event-data-coercion.md`),
    # so a `<param>`-driven map has to agree the same way the `<content>`
    # cases above already do.
    #
    # sabotage: `exit_interpreter/1`'s `%Effect.Done{}` literal's `donedata:`
    # field is hardcoded to `nil` instead of the value `ExitEntry.donedata/2`
    # returned -> `Effect.Done.donedata` would come back `nil` while
    # `Trace.Done.donedata` still carries the param map, reddening the
    # agreement assertion below.
    test "a top-level final's <param> donedata reaches Effect.Done and Trace.Done identically" do
      m = machine()

      {_result, effects} = Interpreter.exit_interpreter(machine_state(m, [idx(:done_param)]))

      assert {:done, %Effect.Done{donedata: effect_donedata}} = List.last(effects)

      assert [%Effect.Trace.Done{donedata: trace_donedata}] =
               for({:trace, %Effect.Trace.Done{} = payload} <- effects, do: payload)

      assert effect_donedata == %{"Var" => 2}
      assert trace_donedata == effect_donedata
    end
  end

  describe "exit_interpreter/1 - onexit runs for every active state" do
    # AC: "onexit content running in exit order for EVERY active state" -
    # a planted configuration (`machine_state/2`, option 3 of the plan's
    # "Testing Strategy") is what puts a leaf and its compound parent both
    # active at once for `exit_interpreter/1` itself, since a normal
    # transition into a top-level final would already have exited both
    # through its own `exit_states/2` pass before `exit_interpreter/1` ever
    # runs.
    #
    # sabotage: `exit_interpreter/1`'s `Machine.exit_order(machine,
    # configuration_at_exit)` call is replaced with `Machine.document_order/2`
    # -> `leaf` and `parent` exit in ascending instead of descending index
    # order, reddening the label-order assertion below.
    test "onexit blocks run for the leaf and its compound parent, in exit order" do
      m = machine()
      ms = machine_state(m, [idx(:parent), idx(:leaf)])

      {result, effects} = Interpreter.exit_interpreter(ms)

      assert log_labels(effects) == ["leaf-exit", "parent-exit"]
      assert result.configuration == MapSet.new()
    end
  end

  describe "exit_interpreter/1 - Trace.ExitSet" do
    # ADR-0012 item 2: the "exit set" row belongs at every phase boundary
    # Appendix D names, and `exitInterpreter` names one - its `statesToExit`
    # is the same variable `exitStates` computes. `Trace.Done` carries the
    # same states as its `configuration`, but after the walk and meaning
    # "the run ended here", so it does not stand in for a marker meaning
    # "these are about to be exited".
    #
    # sabotage: `exit_interpreter/1`'s `exit_set_trace` term is dropped from
    # its returned effect list (`exit_effects ++ done_trace ++
    # [done_effect]`) -> no `Trace.ExitSet` reaches the caller, reddening the
    # match below.
    test "emits the exit set, in exit order, before any state leaves" do
      m = machine()
      ms = machine_state(m, [idx(:parent), idx(:leaf)])

      {_result, effects} = Interpreter.exit_interpreter(ms)

      assert [%Effect.Trace.ExitSet{} = exit_set] =
               for({:trace, %Effect.Trace.ExitSet{} = payload} <- effects, do: payload)

      assert exit_set.indexes == [idx(:leaf), idx(:parent)]

      # Before any state leaves: it precedes both onexit logs, and it names
      # states the post-walk configuration no longer holds.
      assert Enum.find_index(effects, &match?({:trace, %Effect.Trace.ExitSet{}}, &1)) <
               Enum.find_index(effects, &match?({:log, _}, &1))
    end

    # sabotage: `exit_interpreter/1`'s `Trace.ExitSet` emission is built as a
    # bare `[{:trace, Effect.Trace.ExitSet.new(...)}]` list literal instead of
    # going through the gated `Effect.trace/3` macro -> a `trace: false` run
    # carries an ExitSet, reddening the assertion below.
    test "is gated: a trace: false termination emits none" do
      m = machine()
      ms = machine_state(m, [idx(:parent), idx(:leaf)], trace: false)

      {_result, effects} = Interpreter.exit_interpreter(ms)

      assert [] = for({:trace, %Effect.Trace.ExitSet{} = payload} <- effects, do: payload)
    end
  end

  describe "exit_interpreter/1 - Trace.Done" do
    # sabotage: `exit_interpreter/1`'s `configuration_at_exit =
    # machine_state.configuration` binding is moved to *after* the exit
    # fold instead of before it -> `Trace.Done.configuration` comes back
    # empty instead of naming `done`, reddening the non-empty assertion.
    test "carries the configuration as it stood at exit and the matching donedata" do
      m = machine()
      ms = machine_state(m, [idx(:done)])

      {_result, effects} = Interpreter.exit_interpreter(ms)

      assert [%Effect.Trace.Done{} = done_trace] =
               for({:trace, %Effect.Trace.Done{} = payload} <- effects, do: payload)

      assert {:done, %Effect.Done{donedata: core_donedata}} = List.last(effects)

      assert done_trace.configuration == MapSet.new([idx(:done)])
      assert done_trace.donedata == 42
      assert done_trace.donedata == core_donedata
    end

    # This test's other cases in this describe call `exit_interpreter/1`
    # directly on a hand-built machine_state, so they never run a fold and
    # would report `round: 0` - which asserts nothing about depth. This one
    # drives `@document`'s `start` state through the actual fold
    # (`Interpreter.initialize/2`) to the top-level `<final>` it transitions
    # to unconditionally, and reads `Trace.Done`'s round off the result.
    #
    # Probed against the running code rather than derived: `start`'s
    # eventless transition to `done` runs in round 1 (TransitionsSelected,
    # the onexit ExitSet/ContentExecuted, and the EntrySet into `done`); the
    # microstep that entered `done` returns a plain (non-quiescent) tuple
    # with `running: false` already set, so the fold calls `microstep/1`
    # once more, and that `running: false` clause is its own counted round
    # per this plan's "both microstep/1 clauses count" decision - `round: 2`
    # is where `exit_interpreter/1` actually runs and `Trace.Done` is
    # stamped, one more than the round that entered the final state.
    #
    # sabotage: `microstep/1`'s `running: false` clause drops its
    # `begin_round/1` call -> the terminated fold reports one round fewer
    # than the number of `microstep/1` calls it made (`round: 1` instead of
    # `2`), reddening this assertion (and nothing else in the suite, since
    # that clause is the only place a round runs no selection at all).
    test "Trace.Done's round reports the depth of the terminated fold" do
      m = machine()

      {_result, effects} = Interpreter.initialize(m, trace: true)

      assert [%Effect.Trace.Done{round: 2}] =
               for({:trace, %Effect.Trace.Done{} = payload} <- effects, do: payload)
    end
  end

  describe "exit_interpreter/1 - Effect.Done configuration" do
    # sabotage: `exit_interpreter/1`'s `%Effect.Done{}` literal is built with
    # `configuration: machine_state.configuration` (the post-fold, emptied
    # configuration) instead of `configuration_at_exit` -> the non-empty
    # assertion below reddens while the empty `result.configuration` one
    # stays green, pointing at exactly the field this mutation broke.
    test "carries the configuration as it stood at exit, matching Trace.Done, while the returned configuration is empty" do
      m = machine()
      ms = machine_state(m, [idx(:done)])

      {result, effects} = Interpreter.exit_interpreter(ms)

      assert {:done, %Effect.Done{configuration: core_configuration}} = List.last(effects)

      assert [%Effect.Trace.Done{configuration: trace_configuration}] =
               for({:trace, %Effect.Trace.Done{} = payload} <- effects, do: payload)

      assert core_configuration == MapSet.new([idx(:done)])
      assert core_configuration == trace_configuration
      assert result.configuration == MapSet.new()
    end

    # sabotage: same mutation as above (`configuration:
    # machine_state.configuration` instead of `configuration_at_exit`) ->
    # with tracing off there is no `Trace.Done` to cross-check against, so
    # this test is the only coverage that would catch the bug in that mode;
    # the non-empty assertion reddens.
    test "is still populated with tracing off, where there is no Trace.Done to carry it" do
      m = machine()
      ms = machine_state(m, [idx(:done)], trace: false)

      {result, effects} = Interpreter.exit_interpreter(ms)

      assert {:done, %Effect.Done{configuration: core_configuration}} = List.last(effects)
      refute Enum.any?(effects, &match?({:trace, %Effect.Trace.Done{}}, &1))

      assert core_configuration == MapSet.new([idx(:done)])
      assert result.configuration == MapSet.new()
    end
  end

  describe "main_event_loop/1 - quiescence without termination" do
    # AC: "Loop-local storage moved onto the struct ...", exercised here as
    # the negative case of Decision 6's `if machine_state.running` branch.
    #
    # sabotage: `main_event_loop/1`'s `if machine_state.running do ... else
    # exit_interpreter(machine_state) end` guard is inverted to `if not
    # machine_state.running`, so a still-running machine now runs
    # `exit_interpreter/1` -> a spurious `{:done, _}` appears below,
    # reddening the "no {:done, _}" assertion.
    test "emits MacrostepStable, no Trace.Done, and no {:done, _}" do
      m = machine()
      ms = machine_state(m, [idx(:stable)])

      {result, effects} = Interpreter.main_event_loop(ms)

      assert result.running
      assert result.status == :running

      assert [%Effect.Trace.MacrostepStable{}] =
               for({:trace, %Effect.Trace.MacrostepStable{} = payload} <- effects, do: payload)

      refute Enum.any?(effects, &match?({:trace, %Effect.Trace.Done{}}, &1))
      refute Enum.any?(effects, &match?({:done, _}, &1))
    end
  end

  describe "main_event_loop/1 - trace: false" do
    # sabotage: `exit_interpreter/1`'s `Trace.Done` emission is built as a
    # bare `[{:trace, Effect.Trace.Done.new(...)}]` list literal instead of
    # going through the gated `Effect.trace/3` macro -> a `trace: false` run
    # now carries a trace effect, reddening the zero-trace assertion below.
    test "yields zero trace effects while {:done, _} and onexit :logs survive" do
      m = machine()
      ms = machine_state(m, [idx(:start)], trace: false)

      {result, effects} = Interpreter.main_event_loop(ms)

      assert result.status == :done
      assert trace_effects(effects) == []
      assert log_labels(effects) == ["start-exit"]
      assert match?({:done, _}, List.last(effects))
    end
  end

  describe "exit_interpreter/1 - no history recording" do
    # AC: "no history recording matters anymore but the pseudocode records
    # anyway - port as written" (bead description); read here as "record
    # nothing", since Appendix D's `exitInterpreter` has no
    # history-recording loop at all - Decision 10 item 1.
    #
    # sabotage: a spurious `history_values: Map.put(ms.history_values,
    # state_index, MapSet.new())` write is added inside `exit_interpreter/1`'s
    # per-state fold, mirroring `exit_states/2`'s own history-recording pass
    # -> the "history_values unchanged" assertion below reddens.
    test "history_values is unchanged across termination" do
      m = machine()

      ms =
        m
        |> machine_state([idx(:parent), idx(:leaf)])
        |> Map.put(:history_values, %{idx(:h) => MapSet.new([idx(:leaf)])})

      {result, _effects} = Interpreter.exit_interpreter(ms)

      assert result.history_values == ms.history_values
    end
  end
end
