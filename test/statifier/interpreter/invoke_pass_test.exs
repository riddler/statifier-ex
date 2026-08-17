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
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
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

  defp datamodel_change_effects(effects) do
    for {:datamodel_change, %Effect.DatamodelChange{} = payload} <- effects, do: payload
  end

  defp invoke_pass_traces(effects) do
    for {:trace, %Effect.Trace.InvokePass{} = payload} <- effects, do: payload
  end

  defp budget_exhausted_effects(effects) do
    Enum.filter(effects, &match?({:budget_exhausted, _}, &1))
  end

  # `alpha` (index 2) is entered before `beta` (index 3) - entry order is
  # document order here since neither is reached via history - and `beta`
  # carries two invocations in document order. `p` (index 1) itself carries
  # no `<invoke>` children, which is the point: it still lands in
  # `states_to_invoke` during entry but contributes no effect.
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

  # sabotage: `run_invoke_pass/1`'s `invoke_ids = for {:invoke,
  # %Effect.Invoke{invoke_id: invoke_id}} <- effects, do: invoke_id` line is
  # changed to always produce `[]` -> `beta.inv_1`/`beta.inv_2` disappear
  # from `trace.invoke_ids` even though the pass started them, reddening the
  # equality assertion below. Confirmed red and reverted.
  test "the invoke pass emits Trace.InvokePass with the states walked and the invocations started" do
    m = compile!(@parallel_document)
    {result, effects} = Interpreter.initialize(m, trace: true)

    assert [trace] = invoke_pass_traces(effects)
    assert trace.state_indexes == [0, idx(m, "p"), idx(m, "alpha"), idx(m, "beta")]

    assert [alpha_effect, beta1_effect, beta2_effect] = invoke_effects(effects)

    assert trace.invoke_ids == [
             alpha_effect.invoke_id,
             beta1_effect.invoke_id,
             beta2_effect.invoke_id
           ]

    assert MapSet.new() == result.states_to_invoke
  end

  #  0 scxml (root)
  #  1   p       (no <invoke> children at all)
  @no_invoke_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <state id="p"/>
  </scxml>
  """

  # `states_to_invoke` gains every entered state unconditionally
  # (`ExitEntry`'s own comment above its `states_to_invoke: MapSet.put/2`
  # call), root included, so the walk still names both states even though
  # neither owns an `<invoke>` - `invoke_ids` is what stays empty here.
  #
  # sabotage: `run_invoke_pass/1`'s final `{%{machine_state |
  # states_to_invoke: MapSet.new()}, effects ++ trace}` is changed to drop
  # `++ trace` -> no `Trace.InvokePass` is ever appended, reddening the
  # length-one assertion below (and the entry-order test above it, since it
  # relies on the same trace). Confirmed red and reverted.
  test "the invoke pass still emits Trace.InvokePass when nothing was invoked" do
    m = compile!(@no_invoke_document)
    {_result, effects} = Interpreter.initialize(m, trace: true)

    assert [trace] = invoke_pass_traces(effects)
    assert trace.state_indexes == [0, idx(m, "p")]
    assert trace.invoke_ids == []
  end

  # sabotage: `generate_invoke_id/3`'s first clause (`%MInvoke{id: id} when
  # is_binary(id) -> {id, machine_state}`) is deleted, leaving only the
  # generated clause -> the author's literal id is discarded and replaced
  # with a generated one, reddening the equality assertion.
  test "an author-written id is used verbatim" do
    m = compile!(@parallel_document)
    {_result, effects} = Interpreter.initialize(m)

    assert [alpha_effect, _beta1, _beta2] = invoke_effects(effects)
    assert alpha_effect.invoke_id == "inv-alpha"
  end

  # sabotage: `generate_invoke_id/3`'s generated clause is changed from
  # `state.id <> "." <> platformid` to `platformid` alone, dropping the
  # state-id qualifier -> the `beta.inv_` prefix assertion reddens (W3C
  # test224's own shape, ADR-0008 as amended 2026-08-15).
  test "a generated id is qualified by the owning state's id" do
    m = compile!(@parallel_document)
    {_result, effects} = Interpreter.initialize(m)

    assert [_alpha, beta1_effect, beta2_effect] = invoke_effects(effects)
    assert beta1_effect.invoke_id =~ ~r/^beta\.inv_/
    assert beta2_effect.invoke_id =~ ~r/^beta\.inv_/
    refute beta1_effect.invoke_id == beta2_effect.invoke_id
  end

  # sabotage: `MachineState.new/2`'s `invoke_counter: 0` is changed to
  # `invoke_counter: 1` -> both generated ids below shift by one
  # (`beta.inv_2`/`beta.inv_3` instead of `beta.inv_1`/`beta.inv_2`),
  # reddening the exact-value assertions. Confirmed red and reverted.
  test "the invoke counter is session-global, starts at 1, and advances per generation" do
    m = compile!(@parallel_document)
    {_result, effects} = Interpreter.initialize(m)

    assert [_alpha, beta1_effect, beta2_effect] = invoke_effects(effects)
    assert beta1_effect.invoke_id == "beta.inv_1"
    assert beta2_effect.invoke_id == "beta.inv_2"
  end

  # Determinism is ADR-0008's whole point for this generation site: the id
  # is a pure function of `%MachineState{}`, not the wall clock or a CSPRNG,
  # so generating twice from the same initial machine_state produces the
  # same sequence of ids both times.
  #
  # sabotage: `MachineState.new/2`'s `invoke_counter: 0` is changed to
  # `invoke_counter: System.unique_integer([:positive])`, simulating an
  # entropy-seeded counter -> `ids1` and `ids2` start from different bases
  # across the two `initialize/2` calls, reddening the `ids1 == ids2`
  # assertion. Confirmed red and reverted.
  test "generating an invoke id twice from the same machine_state is deterministic" do
    m = compile!(@parallel_document)
    {result1, effects1} = Interpreter.initialize(m)
    {result2, effects2} = Interpreter.initialize(m)

    ids1 = for effect <- invoke_effects(effects1), do: effect.invoke_id
    ids2 = for effect <- invoke_effects(effects2), do: effect.invoke_id

    assert ids1 == ids2
    assert result1.invoke_counter == result2.invoke_counter
  end

  # sabotage: `invoke_one/6`'s `%Effect.Invoke{}` literal is changed from
  # `round: machine_state.round` to `round: 0` -> reddens against this
  # fixture, whose invoke effects are all stamped `round: 1` (the initial
  # entry fold's own first round, not the anonymous round-0 baseline).
  # Confirmed red and reverted.
  test "each invoke effect's round matches the machine state's round it was stamped from" do
    m = compile!(@parallel_document)
    {result, effects} = Interpreter.initialize(m)

    assert [alpha_effect, beta1_effect, beta2_effect] = invoke_effects(effects)
    assert alpha_effect.round == result.round
    assert beta1_effect.round == result.round
    assert beta2_effect.round == result.round
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

  # sabotage: `invoke_one/6`'s effect list is built as `[effect |
  # datamodel_change_effects(...)]` instead of `datamodel_change_effects(...)
  # ++ [effect]` -> the `:datamodel_change` effect would land *after*
  # `:invoke` instead of before it, reddening this test's ordering
  # assertion. Confirmed red and reverted.
  test "idlocation emits a :datamodel_change before :invoke, naming the path, values, and owner" do
    m = compile!(@idlocation_document)
    {:ok, s0_index} = Statifier.Machine.index(m, "s0")
    {result, effects} = Interpreter.initialize(m)

    # `<data id="myid"/>` also binds at initialization, emitting its own
    # `{:datamodel_change, %{d_index: 0, owner: nil}}` ahead of this one -
    # filtered out here since this test is about the idlocation write's own
    # `owner`, not the binding.
    assert [{:datamodel_change, change}, {:invoke, invoke_effect}] =
             for(
               {tag, payload} = effect <- effects,
               tag == :invoke or (tag == :datamodel_change and payload.owner != nil),
               do: effect
             )

    assert change.location_path == ["myid"]
    assert change.location_source == "myid"
    assert change.new_value == invoke_effect.invoke_id
    assert change.prior_value == nil
    assert change.c_index == nil
    assert change.owner == {:invoke, s0_index, 0}
    assert result.datamodel["myid"] == invoke_effect.invoke_id
  end

  #  0 scxml (root)
  #  1   s0      (invoke idlocation="_sessionid" - a system-variable root, always rejected)
  @failing_idlocation_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke idlocation="_sessionid" type="t"/>
      </state>
  </scxml>
  """

  # sabotage: `invoke_one/6`'s `{:error, reason} -> {abort_invocation(...),
  # context, []}` branch is changed to also append
  # `datamodel_change_effects(...)` (folding the failure and success
  # branches' effect-building together) -> this test's empty-list assertion
  # reddens, since the failed write would still surface a
  # `:datamodel_change`. Confirmed red and reverted.
  test "a failing idlocation write emits no :datamodel_change effect" do
    m = compile!(@failing_idlocation_document)
    {_result, effects} = Interpreter.initialize(m)

    assert invoke_effects(effects) == []
    assert datamodel_change_effects(effects) == []
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
