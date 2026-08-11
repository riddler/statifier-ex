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
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
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
  #  6   done            -- top-level <final>; static donedata "42"
  #  7   done_nil        -- top-level <final>; no <donedata>
  #  8   done_compiled   -- top-level <final>; donedata with an expr (deferred to nil)
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
    done_compiled: 8
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

  describe "exit_interpreter/1 - donedata" do
    # sabotage: `exit_interpreter/1`'s `ExitEntry.static_donedata(machine,
    # state_index)` call is replaced with a hardcoded `nil` -> the static
    # "42" case below reddens while the already-nil cases stay green,
    # pointing at exactly the wiring this mutation broke.
    test "static donedata rides the terminal effect; absent and compiled donedata are nil" do
      m = machine()

      {static_result, static_effects} =
        Interpreter.exit_interpreter(machine_state(m, [idx(:done)]))

      assert {:done, %Effect.Done{donedata: "42"}} = List.last(static_effects)
      assert static_result.status == :done

      {_result, absent_effects} = Interpreter.exit_interpreter(machine_state(m, [idx(:done_nil)]))
      assert {:done, %Effect.Done{donedata: nil}} = List.last(absent_effects)

      {_result, compiled_effects} =
        Interpreter.exit_interpreter(machine_state(m, [idx(:done_compiled)]))

      assert {:done, %Effect.Done{donedata: nil}} = List.last(compiled_effects)
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
      assert done_trace.donedata == "42"
      assert done_trace.donedata == core_donedata
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
