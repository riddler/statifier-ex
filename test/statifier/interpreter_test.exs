defmodule Statifier.InterpreterTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Machine
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

  defp state_index(machine, id) do
    {:ok, index} = Machine.index(machine, id)
    index
  end

  # AC: "a top-level <script> whose write is visible in the initial state's
  # cond" - the write happens at initialize/2's executeGlobalScriptElement
  # position, strictly before the initialization macrostep's own eventless
  # selection round, so an eventless transition guarded on the written
  # value is already enabled the first time selection runs.
  #
  # sabotage: `Statifier.Interpreter.initialize/2`'s
  # `run_global_scripts(machine_state, machine.global_scripts)` call is
  # dropped (bound to `_` and discarded instead of rebinding
  # `machine_state`) -> confirmed red: `x` stays unbound (`nil`), `x == 1`
  # fails to evaluate true, the eventless transition is never enabled, and
  # `result.configuration` stays at `a` instead of reaching `b`. Reverted
  # and confirmed green.
  test "a top-level <script> write is visible in the initial state's cond" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <datamodel>
              <data id="x"/>
          </datamodel>
          <state id="a">
              <transition cond="x == 1" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """)

    {result, _effects} = Interpreter.initialize(machine)

    assert result.configuration == MapSet.new([0, state_index(machine, "b")])
    assert result.datamodel["x"] == 1
  end

  # AC: "a top-level <script> declaring a root no <datamodel> names
  # (test304's shape)" - Decision 2's asymmetry with <assign>: a predicator
  # assignment statement is a declaration and a write in one, so `Var1`
  # need not appear in any <datamodel> for the write to land.
  #
  # sabotage: `Statifier.Interpreter.initialize/2`'s
  # `run_global_scripts(machine_state, machine.global_scripts)` call is
  # dropped (bound to `_` and discarded instead of rebinding
  # `machine_state`) -> confirmed red: `Var1` is never written, reddening
  # the assertion below. Reverted and confirmed green.
  test "a top-level <script> may declare a root no <datamodel> names" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>Var1 = 1;</script>
          <state id="a"/>
      </scxml>
      """)

    {result, _effects} = Interpreter.initialize(machine)

    assert result.datamodel["Var1"] == 1
  end

  # AC: "two top-level <script> children running in document order" - the
  # second script's body reads the first's write, so an out-of-order fold
  # (or one that does not thread the mutated machine_state forward) would
  # leave `x` at `1` instead of `2`.
  #
  # sabotage: `Statifier.Interpreter.run_global_scripts/2`'s pipeline gains
  # an `Enum.reverse/1` before `Enum.with_index/1` (runs the scripts
  # last-to-first) -> confirmed red: `x` ends at `1`, not `2`. `x = x + 1;`
  # now runs first, against a still-nonexistent `x` (on_unbound: :error),
  # so that statement fails and writes nothing; `x = 1;` then runs second
  # and is the only write that lands, reddening the equality assertion
  # below. Reverted and confirmed green.
  test "two top-level <script> children run in document order" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <script>x = x + 1;</script>
          <state id="a"/>
      </scxml>
      """)

    {result, _effects} = Interpreter.initialize(machine)

    assert result.datamodel["x"] == 2
  end

  # AC: "a failing top-level script leaving prior writes in place and
  # queueing exactly one error.execution that the initialization macrostep
  # dequeues" - the first statement's write survives the second
  # statement's failure (ADR-0026 decision 1's stop-and-keep model), and
  # the raised error.execution is caught inside the very same
  # `initialize/2` call, since main_event_loop/1 folds the initialization
  # macrostep to quiescence before returning.
  #
  # sabotage: `Statifier.Interpreter.run_global_script/3`'s `{:error,
  # new_machine_state, error}` clause is changed to raise on the *original*
  # (pre-failure) `machine_state` argument instead of `new_machine_state`
  # -> confirmed red: `result.datamodel["x"]` is `nil`, not `1` - the
  # write `x = 1;` already made lands on `new_machine_state`, which this
  # mutation discards in favor of raising against (and returning) the
  # stale pre-run state, so the earlier write never survives the call.
  # Reverted and confirmed green.
  test "a failing top-level script keeps its prior write and its error.execution is caught in the same initialize/2 call" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1; y = nope + 1;</script>
          <state id="a">
              <transition event="error.execution" target="caught"/>
          </state>
          <state id="caught"/>
      </scxml>
      """)

    {result, _effects} = Interpreter.initialize(machine)

    assert result.datamodel["x"] == 1
    assert MachineState.internal_events(result) == []
    assert result.configuration == MapSet.new([0, state_index(machine, "caught")])
  end

  # AC: "a top-level script running before the initial state is entered (an
  # <onentry> on the initial state reads the written value)" - proves the
  # call site's position (between Datamodel.initialize/1 and
  # ExitEntry.enter_states/2), not merely that the write eventually lands.
  #
  # sabotage: `Statifier.Interpreter.initialize/2`'s
  # `run_global_scripts(machine_state, machine.global_scripts)` call is
  # moved to *after* the `ExitEntry.enter_states/2` call instead of before
  # it -> confirmed red: `result.datamodel["y"]` is `nil`, not `2` - state
  # "a"'s own <onentry> script runs before the top-level script has
  # written `x`, so `y = x + 1;` fails against a nonexistent `x`
  # (Evaluator.context/1's on_unbound: :error) instead of computing `2`.
  # Reverted and confirmed green.
  test "a top-level script runs before the initial state is entered" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <state id="a">
              <onentry>
                  <script>y = x + 1;</script>
              </onentry>
          </state>
      </scxml>
      """)

    {result, _effects} = Interpreter.initialize(machine)

    assert result.datamodel["x"] == 1
    assert result.datamodel["y"] == 2
  end

  # AC: "a top-level script whose body does not parse (deferred-to-runtime
  # path, raises error.execution at load-time position)" - Decision 1: an
  # unparseable body defers its failure from compile/1 (which still
  # succeeds) to the point it is reached at runtime, here the load-time
  # executeGlobalScriptElement position.
  #
  # sabotage: `Statifier.Interpreter.run_global_script/3`'s `{:invalid,
  # error}` clause is deleted -> confirmed red: a `FunctionClauseError` at
  # `run_global_script/3` (no clause matches `{:invalid, _}` against the
  # remaining `{:program, ...}` clause) - the deferred-compile-failure
  # shape reaches this exact function and needs its own clause, precisely
  # what this test pins. Reverted and confirmed green.
  test "a top-level script whose body does not parse defers to runtime and raises error.execution when reached" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>var x = 1</script>
          <state id="a">
              <transition event="error.execution" target="caught"/>
          </state>
          <state id="caught"/>
      </scxml>
      """)

    assert [{:invalid, %Statifier.Compiler.Error{}}] = machine.global_scripts

    {result, _effects} = Interpreter.initialize(machine)

    assert MachineState.internal_events(result) == []
    assert result.configuration == MapSet.new([0, state_index(machine, "caught")])
  end
end
