defmodule Statifier.Interpreter.InvokePassTest do
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
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  defp invoke_effects(effects) do
    for {:invoke, %Effect.Invoke{} = payload} <- effects, do: payload
  end

  defp budget_exhausted_effects(effects) do
    Enum.filter(effects, &match?({:budget_exhausted, _}, &1))
  end

  # `alpha` (index 2) is entered before `beta` (index 3) - entry order is
  # document order here since neither is reached via history - and `beta`
  # carries two invocations in document order. `p` (index 1) itself carries
  # no `<invoke>` children, which is the point: it still lands in
  # `states_to_invoke` (Phase 5) but contributes no effect.
  #
  #  0 scxml (root)
  #  1   p       (parallel)
  #  2     alpha   (invoke id="inv-alpha")
  #  3     beta    (invoke type="t.beta.1"; invoke type="t.beta.2")
  @parallel_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <parallel id="p">
          <state id="alpha">
              <invoke id="inv-alpha" type="t.alpha"/>
          </state>
          <state id="beta">
              <invoke type="t.beta.1"/>
              <invoke type="t.beta.2"/>
          </state>
      </parallel>
  </scxml>
  """

  # sabotage: `run_invoke_pass/1`'s `Machine.document_order(machine,
  # machine_state.states_to_invoke)` is changed to
  # `Enum.reverse(Machine.document_order(...))` -> beta's invocations are
  # emitted before alpha's, reddening the state_index ordering assertion.
  test "the invoke pass emits effects in entry order across states, document order within a state" do
    m = compile!(@parallel_document)
    {result, effects} = Interpreter.initialize(m)

    assert [alpha_effect, beta1_effect, beta2_effect] = invoke_effects(effects)

    assert alpha_effect.state_index == idx(m, "alpha")
    assert alpha_effect.type == "t.alpha"

    assert beta1_effect.state_index == idx(m, "beta")
    assert beta1_effect.type == "t.beta.1"

    assert beta2_effect.state_index == idx(m, "beta")
    assert beta2_effect.type == "t.beta.2"

    assert MapSet.new() == result.states_to_invoke
  end

  # sabotage: `generate_invoke_id/2`'s first clause (`%MInvoke{id: id} when
  # is_binary(id) -> id`) is deleted, leaving only the generated clauses ->
  # the author's literal id is discarded and replaced with a generated one,
  # reddening the equality assertion.
  test "an author-written id is used verbatim" do
    m = compile!(@parallel_document)
    {_result, effects} = Interpreter.initialize(m)

    assert [alpha_effect, _beta1, _beta2] = invoke_effects(effects)
    assert alpha_effect.invoke_id == "inv-alpha"
  end

  # sabotage: `generate_invoke_id/2`'s state-qualified clause
  # (`state_id <> "." <> UXID.generate!(prefix: "inv")`) is changed to
  # `UXID.generate!(prefix: "inv")` alone, dropping the state-id qualifier
  # -> the `beta.inv_` prefix assertion reddens (W3C test224's own shape,
  # ADR-0008 as amended).
  test "a generated id is qualified by the owning state's id" do
    m = compile!(@parallel_document)
    {_result, effects} = Interpreter.initialize(m)

    assert [_alpha, beta1_effect, beta2_effect] = invoke_effects(effects)
    assert beta1_effect.invoke_id =~ ~r/^beta\.inv_/
    assert beta2_effect.invoke_id =~ ~r/^beta\.inv_/
    refute beta1_effect.invoke_id == beta2_effect.invoke_id
  end

  #  0 scxml (root)
  #  1   s0      (invoke idlocation="myid")
  @idlocation_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="myid"/>
      </datamodel>
      <state id="s0">
          <invoke idlocation="myid" type="t"/>
      </state>
  </scxml>
  """

  # sabotage: `invoke_one/6`'s `maybe_write_idlocation/4` call is replaced
  # with `{:ok, machine_state, context}` unconditionally, dropping the write
  # -> `myid` stays `nil` instead of the generated invoke id, reddening the
  # assertion.
  test "idlocation writes the generated invoke id into the datamodel" do
    m = compile!(@idlocation_document)
    {result, effects} = Interpreter.initialize(m)

    assert [invoke_effect] = invoke_effects(effects)
    assert result.datamodel["myid"] == invoke_effect.invoke_id
    assert invoke_effect.invoke_id =~ ~r/^s0\.inv_/
  end

  #  0 scxml (root)
  #  1   s0      (invoke typeexpr="undefined_var" fails; invoke type="fine" ok)
  @failing_sibling_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke typeexpr="undefined_var"/>
          <invoke id="ok" type="fine"/>
      </state>
  </scxml>
  """

  # sabotage: `invoke_one/6`'s `with` chain's first clause,
  # `{:ok, type} <- resolve_expr(context, invoke.type)`, is replaced with
  # `{:ok, type} <- {:ok, nil}`, bypassing the failing `typeexpr`'s own
  # evaluation -> the failing invocation's own `Effect.Invoke` reappears
  # (with `type: nil`), reddening the length-one assertion below.
  test "a failing typeexpr raises error.execution and produces no effect, but a sibling still does" do
    m = compile!(@failing_sibling_document)
    {result, effects} = Interpreter.initialize(m)

    assert [ok_effect] = invoke_effects(effects)
    assert ok_effect.invoke_id == "ok"

    # `s0` has no transition on `error.execution`, so the post-invoke
    # re-check dequeues and discards it before `initialize/2` returns
    # (Appendix D's own "iterate to handle them" - nothing to handle here
    # but the dequeue still happens); the raised event's effect is the
    # absent `Effect.Invoke` above, not a surviving queue entry.
    assert MachineState.internal_events(result) == []
    assert result.running
  end

  #  0 scxml (root)
  #  1   s0      (transition event="go" -> s1)
  #  2   s1      (invoke typeexpr="undefined_var"; transition event="error.execution" -> s2)
  #  3   s2
  @recheck_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <transition event="go" target="s1"/>
      </state>
      <state id="s1">
          <invoke typeexpr="undefined_var"/>
          <transition event="error.execution" target="s2"/>
      </state>
      <state id="s2"/>
  </scxml>
  """

  # sabotage: `main_event_loop/3`'s `true -> main_event_loop(machine_state,
  # effects, budget)` re-entry clause is replaced with
  # `true -> {machine_state, effects}`, dropping the `continue` self-call ->
  # the raised `error.execution` is never dequeued within this
  # `handle_event/2` call, so the configuration stays at `s1` instead of
  # reaching `s2`, reddening the configuration assertion. Confirmed red
  # (alongside the "exactly one terminal effect" test below, which the
  # same mutation also reddens) and reverted.
  test "the post-invoke re-check handles a raised error.execution inside the same handle_event/2 call" do
    m = compile!(@recheck_document)
    {ms, _effects} = Interpreter.initialize(m)

    assert {:ok, result, _effects} = Interpreter.handle_event(ms, Event.external("go"))

    assert result.configuration == MapSet.new([0, idx(m, "s2")])
  end

  # Same document as the re-check test above: two folds happen inside one
  # `handle_event/2` call (s0->s1, then the re-entry that dequeues
  # error.execution and runs s1->s2), so this pins ADR-0032's "exactly one
  # terminal effect per main_event_loop/1 call" property against a real
  # re-entry, not just the equivalence claim for a no-invoke document the
  # macrostep suite already covers.
  #
  # sabotage: `main_event_loop/3`'s `true -> main_event_loop(machine_state,
  # effects, budget)` re-entry clause is replaced with
  # `true -> {machine_state, effects}`, dropping the `continue` self-call ->
  # the re-entry that would have dequeued `error.execution` and reached
  # `s2` never runs, so `main_event_loop/1` returns with `running: true`
  # and *no* terminal effect at all, reddening the length-one assertion
  # below (the same mutation the re-check test above uses). Confirmed red
  # and reverted.
  test "exactly one terminal effect is emitted per handle_event/2 call across a re-entry" do
    m = compile!(@recheck_document)
    {ms, _effects} = Interpreter.initialize(m, trace: true)

    assert {:ok, _result, effects} = Interpreter.handle_event(ms, Event.external("go"))

    stable = for {:trace, %Effect.Trace.MacrostepStable{}} <- effects, do: :stable
    done = for {:done, _payload} <- effects, do: :done
    exhausted = budget_exhausted_effects(effects)

    assert length(stable) + length(done) + length(exhausted) == 1
  end

  #  0 scxml (root)
  #  1   a       (invoke typeexpr="undefined_var"; transition event="error.execution" -> b)
  #  2   b       (invoke typeexpr="undefined_var"; transition event="error.execution" -> a)
  @livelock_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke typeexpr="undefined_var"/>
          <transition event="error.execution" target="b"/>
      </state>
      <state id="b">
          <invoke typeexpr="undefined_var"/>
          <transition event="error.execution" target="a"/>
      </state>
  </scxml>
  """

  @tag timeout: 2_000
  # ADR-0032's own scenario: two states whose <invoke> arguments
  # deterministically fail hand each other control forever via
  # error.execution, unless the round budget spans the invoke re-entry
  # rather than resetting on every re-entrant fold.
  #
  # sabotage: `main_event_loop/1`'s delegation is changed from
  # `main_event_loop(machine_state, [], machine_state.max_macrostep_rounds)`
  # to always pass `machine_state.max_macrostep_rounds` fresh at
  # `main_event_loop/3`'s own recursive `continue` call too (i.e. the
  # re-entry ignores the threaded `budget` and restarts from
  # `machine_state.max_macrostep_rounds` every time) -> the fold never
  # exhausts and the test hangs. Bounded with `@tag timeout: 2_000` above
  # while confirming red, so the mutation costs about two seconds instead
  # of ExUnit's 60-second default.
  test "the round budget spans invoke re-entries and exhausts rather than looping forever" do
    m = compile!(@livelock_document)

    {result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 5)

    assert [{:budget_exhausted, %Effect.BudgetExhausted{budget: 5}}] =
             budget_exhausted_effects(effects)

    assert result.running
  end
end
