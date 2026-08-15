defmodule Statifier.InterpreterTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
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

  # AC: "a top-level <script> emits a trace effect when tracing is on,
  # carrying the {:global_script, index} owner" - closes the asymmetry with
  # `Statifier.Interpreter.Content.execute_block/3`, which already emits
  # `Trace.ContentExecuted` for the identical script body inside an
  # <onentry>.
  #
  # sabotage: `run_global_script/3`'s compiled-program clause has its
  # `Effect.trace(...)` call deleted, returning `{machine_state, []}`
  # unconditionally -> confirmed red: `effects` no longer contains a
  # `Trace.ContentExecuted` payload, reddening the pattern match below.
  # Reverted and confirmed green.
  test "a top-level <script> emits Trace.ContentExecuted with the {:global_script, index} owner when tracing is on" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <state id="a"/>
      </scxml>
      """)

    {_result, effects} = Interpreter.initialize(machine, trace: true)

    assert %Effect.Trace.ContentExecuted{owner: {:global_script, 0}, c_indexes: []} =
             Enum.find_value(effects, fn
               {:trace, %Effect.Trace.ContentExecuted{} = payload} -> payload
               _other -> nil
             end)
  end

  # AC: "an untraced run emits nothing" - the same load-time script, with
  # `trace: false` (`Interpreter.initialize/2`'s own default), produces no
  # `Trace.ContentExecuted` effect at all rather than one with an empty
  # payload.
  #
  # sabotage: `Effect.trace/3`'s own `if machine_state.trace do` guard
  # (`lib/statifier/effect.ex`) is inverted to `if not machine_state.trace
  # do` -> confirmed red: an untraced `initialize/2` call now emits
  # `Trace.ContentExecuted` (among every other trace effect in the run),
  # reddening the refutation below. Reverted and confirmed green.
  test "an untraced top-level <script> emits no trace effect" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <state id="a"/>
      </scxml>
      """)

    {_result, effects} = Interpreter.initialize(machine)

    refute Enum.any?(effects, &match?({:trace, %Effect.Trace.ContentExecuted{}}, &1))
  end

  # AC: "the effect is emitted on the error path too, matching the block
  # runner's error-path emission" - `execute_block/3`'s error clause still
  # emits `Trace.ContentExecuted` (with `c_indexes` truncated to what ran);
  # `run_global_script/3`'s error clause mirrors that rather than skipping
  # the trace once `error.execution` has been raised.
  #
  # sabotage: `run_global_script/3`'s compiled-program clause has its
  # `Effect.trace(...)` call deleted, returning `{machine_state, []}`
  # unconditionally (the same mutation the first test above uses, which also
  # reddens this test since both the success and error arms of that clause
  # share the one trace call after the `case`) -> confirmed red: `effects`
  # for the failing script carries no `Trace.ContentExecuted` payload,
  # reddening the pattern match below. Reverted and confirmed green.
  test "a failing top-level <script> still emits Trace.ContentExecuted" do
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

    {_result, effects} = Interpreter.initialize(machine, trace: true)

    assert %Effect.Trace.ContentExecuted{owner: {:global_script, 0}, c_indexes: []} =
             Enum.find_value(effects, fn
               {:trace, %Effect.Trace.ContentExecuted{} = payload} -> payload
               _other -> nil
             end)
  end

  # AC: "the effects order before enterStates' effects in initialize/2's
  # return" - `run_global_scripts/2`'s own `Trace.ContentExecuted` must
  # precede `ExitEntry.enter_states/2`'s `Trace.EntrySet` in the flat list
  # `initialize/2` returns, matching Appendix D's `executeGlobalScriptElement`
  # running strictly before `enterStates`.
  #
  # sabotage: `initialize/2`'s final tuple is changed from `{machine_state,
  # global_effects ++ enter_effects ++ loop_effects}` to `{machine_state,
  # enter_effects ++ global_effects ++ loop_effects}` -> confirmed red: the
  # global script's `Trace.ContentExecuted` now lands after the initial
  # state's `Trace.EntrySet` instead of before it, reddening the ordering
  # assertion below. Reverted and confirmed green.
  test "a top-level <script>'s trace effect orders before enterStates' effects" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = 1;</script>
          <state id="a"/>
      </scxml>
      """)

    {_result, effects} = Interpreter.initialize(machine, trace: true)

    content_executed_index =
      Enum.find_index(effects, &match?({:trace, %Effect.Trace.ContentExecuted{}}, &1))

    entry_set_index = Enum.find_index(effects, &match?({:trace, %Effect.Trace.EntrySet{}}, &1))

    assert content_executed_index < entry_set_index
  end

  describe "cancel/1" do
    defp cancel_document do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="parent">
          <state id="parent">
              <onexit>
                  <log label="parent-exit"/>
              </onexit>
              <initial>
                  <transition target="leaf"/>
              </initial>
              <state id="leaf">
                  <onexit>
                      <log label="leaf-exit"/>
                  </onexit>
              </state>
          </state>
      </scxml>
      """
    end

    defp log_labels(effects) do
      for {:log, %Effect.Log{label: label}} <- effects, do: label
    end

    # sabotage: `cancel/1`'s `%{machine_state | running: false}` update is
    # dropped so `exit_interpreter/1` runs against the still-`running: true`
    # machine_state -> `exit_interpreter/1` never touches `running` itself,
    # so the returned position comes back with `running: true`, reddening
    # `refute result.running` below. Reverted and confirmed green.
    test "cancels a running chart mid-configuration: {:done, _} carries the pre-exit configuration, status is :done, running is false" do
      machine = compile!(cancel_document())
      {running, _effects} = Interpreter.initialize(machine)
      pre_exit_configuration = running.configuration

      assert running.running

      assert {:ok, result, effects} = Interpreter.cancel(running)

      assert {:done, %Effect.Done{configuration: done_configuration}} = List.last(effects)
      assert done_configuration == pre_exit_configuration
      assert result.status == :done
      refute result.running
    end

    # sabotage: `cancel/1`'s returned effect list is built as
    # `Enum.reverse(effects)` instead of `effects` -> `exit_interpreter/1`'s
    # own onexit order (leaf, then its compound parent) comes back reversed,
    # reddening the label-order assertion below. Reverted and confirmed
    # green.
    test "runs onexit blocks for every active state in exit order" do
      machine = compile!(cancel_document())
      {running, _effects} = Interpreter.initialize(machine)

      assert {:ok, _result, effects} = Interpreter.cancel(running)

      assert log_labels(effects) == ["leaf-exit", "parent-exit"]
    end

    # sabotage: `cancel/1`'s `%{machine_state | running: false}` update is
    # dropped (same mutation as the first test above) -> the cancelled
    # position comes back with `running: true`, so the subsequent
    # `handle_event/2` no longer hits its `running: false` guard clause and
    # is accepted instead of rejected, reddening the `{:error,
    # :not_running}` match below. Reverted and confirmed green.
    test "a cancelled chart rejects a subsequent handle_event/2 with {:error, :not_running}" do
      machine = compile!(cancel_document())
      {running, _effects} = Interpreter.initialize(machine)

      assert {:ok, cancelled, _effects} = Interpreter.cancel(running)

      assert Interpreter.handle_event(cancelled, Event.external("go")) ==
               {:error, :not_running}
    end

    # sabotage: `cancel/1`'s `%MachineState{running: false}` head clause is
    # deleted, leaving only the general clause -> cancelling an
    # already-terminated machine_state falls through to the general clause,
    # which re-runs `exit_interpreter/1` over an already-empty configuration
    # and returns `{:ok, _, _}` instead of `{:error, :not_running}`,
    # reddening the match below. Reverted and confirmed green.
    test "cancelling an already-done chart returns {:error, :not_running}" do
      machine = compile!(cancel_document())
      {running, _effects} = Interpreter.initialize(machine)
      assert {:ok, done, _effects} = Interpreter.cancel(running)

      assert Interpreter.cancel(done) == {:error, :not_running}
    end

    # sabotage: same `Enum.reverse(effects)` mutation as the onexit-order
    # test above -> `Trace.ExitSet` no longer precedes the onexit logs and
    # `Trace.Done` no longer precedes the terminal `{:done, _}`, the same
    # relative positions natural termination (`exit_interpreter/1` itself)
    # produces, reddening the ordering assertions below. Reverted and
    # confirmed green.
    test "with trace: true, ExitSet and Trace.Done appear in the same positions natural termination produces" do
      machine = compile!(cancel_document())
      {running, _effects} = Interpreter.initialize(machine, trace: true)

      assert {:ok, _result, effects} = Interpreter.cancel(running)

      exit_set_index =
        Enum.find_index(effects, &match?({:trace, %Effect.Trace.ExitSet{}}, &1))

      first_log_index = Enum.find_index(effects, &match?({:log, _payload}, &1))

      done_trace_index =
        Enum.find_index(effects, &match?({:trace, %Effect.Trace.Done{}}, &1))

      done_effect_index = Enum.find_index(effects, &match?({:done, _payload}, &1))

      assert exit_set_index < first_log_index
      assert done_trace_index < done_effect_index
      assert done_effect_index == length(effects) - 1
    end
  end

  # -- deliver_internal/5 (ADR-0037) ---------------------------------------

  describe "deliver_internal/5" do
    defp two_state_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `deliver_internal/5`'s `:internal ->` clause calls
    # `MachineState.raise_platform/4` instead of `raise_internal/4` -> the
    # delivered event's `type` reads `:platform` instead of `:internal`,
    # reddening the type assertion below. Reverted and confirmed green.
    test "kind: :internal raises through raise_internal/4 and runs to quiescence" do
      machine = compile!(two_state_doc())
      {running, _effects} = Interpreter.initialize(machine, trace: true)

      assert {:ok, result, effects} =
               Interpreter.deliver_internal(running, :internal, "e", {:state, 0}, [])

      assert result.configuration == MapSet.new([0, state_index(machine, "b")])

      assert Enum.any?(
               effects,
               &match?(
                 {:trace, %Effect.Trace.EventDequeued{event: %Event{type: :internal, name: "e"}}},
                 &1
               )
             )
    end

    # sabotage: `deliver_internal/5`'s `:platform ->` clause calls
    # `MachineState.raise_internal/4` instead of `raise_platform/4` -> the
    # delivered event's `type` reads `:internal` instead of `:platform`,
    # reddening the type assertion below. Reverted and confirmed green.
    test "kind: :platform raises through raise_platform/4" do
      machine = compile!(two_state_doc())
      {running, _effects} = Interpreter.initialize(machine, trace: true)

      assert {:ok, _result, effects} =
               Interpreter.deliver_internal(running, :platform, "e", {:state, 0}, [])

      assert Enum.any?(
               effects,
               &match?(
                 {:trace, %Effect.Trace.EventDequeued{event: %Event{type: :platform, name: "e"}}},
                 &1
               )
             )
    end

    # sabotage: `deliver_internal/5`'s `opts` argument is dropped from the
    # `raise_internal/4`/`raise_platform/4` call (hardcoded to `[]`) -> the
    # `sendid` passed through `opts` never reaches the delivered event, so
    # `_event.sendid` reads `nil` instead of `"send1"`, reddening the
    # assertion below. Reverted and confirmed green.
    test "opts (sendid) pass through to the delivered event" do
      machine = compile!(two_state_doc())
      {running, _effects} = Interpreter.initialize(machine)

      assert {:ok, result, _effects} =
               Interpreter.deliver_internal(running, :internal, "e", {:state, 0}, sendid: "send1")

      assert result.configuration == MapSet.new([0, state_index(machine, "b")])
      assert result.datamodel["_event"]["sendid"] == "send1"
    end

    # sabotage: `deliver_internal/5`'s `%MachineState{running: false}` head
    # clause is deleted, leaving only the general clause -> calling it on an
    # already-terminated machine_state falls through to the general clause
    # instead of returning `{:error, :not_running}`, reddening the match
    # below. Reverted and confirmed green.
    test "rejects an already-terminated machine_state with {:error, :not_running}" do
      machine = compile!(two_state_doc())
      {running, _effects} = Interpreter.initialize(machine)
      assert {:ok, done, _effects} = Interpreter.cancel(running)

      assert Interpreter.deliver_internal(done, :internal, "e", {:state, 0}, []) ==
               {:error, :not_running}
    end
  end
end
