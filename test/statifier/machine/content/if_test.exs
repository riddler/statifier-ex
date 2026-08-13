defmodule Statifier.Machine.Content.IfTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Log
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Lowering
  alias Statifier.Machine.Content.If
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.TestContent
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Five plain <log> nodes, c0..c4 - real, addressable content cells that
  # individual tests substitute via `machine_with_node/3`, the same
  # fixture-preserving technique `content_test.exs` uses.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <log label="c0"/>
              <log label="c1"/>
              <log label="c2"/>
              <log label="c3"/>
              <log label="c4"/>
          </onentry>
      </state>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp location, do: Location.at_offset("", 0)
  @owner {:onentry, 0, 0}

  defp machine_with_node(machine, c_index, node) do
    %{machine | contents: put_elem(machine.contents, c_index, node)}
  end

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  defp context(machine) do
    ms = MachineState.new(machine)
    %Context{machine_state: ms, owner: @owner, datamodel_context: Evaluator.context(ms)}
  end

  defp branch(cond_expr, content) do
    %If.Branch{cond: cond_expr, cond_location: nil, content: content}
  end

  defp if_node(branches) do
    %If{c_index: 99, location: location(), branches: branches}
  end

  # sabotage: `select/3`'s clauses are reordered so the fold keeps scanning
  # past a matched `{:ok, true}` branch instead of returning immediately
  # (the last matching branch wins instead of the first) -> this test's
  # assertion that branch 0's effect (not branch 1's) ran would redden.
  test "the first true branch wins even when a later branch is also true" do
    node =
      if_node([
        branch({:static, true}, [0]),
        branch({:static, true}, [1])
      ])

    assert {:ok, ctx, [{:log, %Log{}}]} = ExecutableContent.execute(node, context(machine()))
    assert [{:log, %{label: "c0"}}] = elem(ExecutableContent.execute(node, context(machine())), 2)
    assert ctx.pending_errors == []
  end

  # sabotage: `select/3`'s `%If.Branch{cond: nil}` clause is deleted, so
  # `<else>` never selects unconditionally and instead falls through to the
  # empty-branches base case -> this test's effect assertion reddens
  # (nothing would run).
  test "<else> runs when every earlier cond is false" do
    node =
      if_node([
        branch({:static, false}, [0]),
        branch(nil, [1])
      ])

    assert {:ok, _ctx, [{:log, %Log{label: "c1"}}]} =
             ExecutableContent.execute(node, context(machine()))
  end

  # sabotage: `execute/2`'s `nil` selected-branch clause is changed to fall
  # back to running the *first* branch's content instead of returning
  # `{:ok, context, []}` -> this test's empty-effects assertion reddens.
  test "nothing runs when every cond is false and there is no <else>" do
    node = if_node([branch({:static, false}, [0]), branch({:static, false}, [1])])

    assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))
    assert ctx.pending_errors == []
  end

  # sabotage: `run_partition/2`'s `Enum.reduce_while/3` starting accumulator
  # is changed from `{:ok, context, []}` to `{:ok, context, [:sentinel]}` ->
  # this test's exact-match on an empty effect list reddens.
  test "an empty partition returns {:ok, context, []}" do
    node = if_node([branch(nil, [])])

    assert {:ok, _ctx, []} = ExecutableContent.execute(node, context(machine()))
  end

  # sabotage: `run_partition/2`'s fold accumulates `node_effects ++ effects`
  # instead of `effects ++ node_effects` -> the two logs' effects would come
  # back reversed, reddening this ordered match.
  test "a multi-node partition's effects come back in document order" do
    node = if_node([branch(nil, [0, 1])])

    assert {:ok, _ctx, [{:log, %Log{label: "c0"}}, {:log, %Log{label: "c1"}}]} =
             ExecutableContent.execute(node, context(machine()))
  end

  # sabotage: `select/3`'s `{:ok, other}` clause is collapsed into the
  # `{:ok, false}` clause (treating a non-boolean cond as plain `false`
  # with no reason recorded) -> `ctx.pending_errors` would come back `[]`
  # instead of `[{:non_boolean_cond, 5}]`, reddening this assertion.
  test "an erroring cond puts one reason in pending_errors and the scan continues" do
    node =
      if_node([
        branch({:static, 5}, [0]),
        branch(nil, [1])
      ])

    assert {:ok, ctx, [{:log, %Log{label: "c1"}}]} =
             ExecutableContent.execute(node, context(machine()))

    assert ctx.pending_errors == [{:non_boolean_cond, 5}]
  end

  # sabotage: `select/3`'s `{:ok, other}` clause's reason is changed from
  # `{:non_boolean_cond, other}` to a bare `other` (dropping the tag
  # `Statifier.Interpreter.Selection.evaluate_cond/2` also uses) -> this
  # pattern match on the tagged reason reddens.
  test "a non-boolean cond yields a {:non_boolean_cond, value} reason" do
    node = if_node([branch({:static, "yes"}, [0])])

    assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))
    assert ctx.pending_errors == [{:non_boolean_cond, "yes"}]
  end

  # sabotage: `select/3`'s `{:error, %Evaluator.Error{}}` clause drops the
  # error from `reasons` instead of prepending it (`select(rest,
  # datamodel_context, reasons)` instead of `[error | reasons]`) -> the
  # second reason in this test's ordered-match would go missing, reddening
  # the assertion.
  test "two failing conds accumulate two reasons in order, then <else> runs" do
    node =
      if_node([
        branch({:static, "x"}, [0]),
        branch(compiled_expr("undefined_var"), [1]),
        branch(nil, [2])
      ])

    assert {:ok, ctx, [{:log, %Log{label: "c2"}}]} =
             ExecutableContent.execute(node, context(machine()))

    assert [{:non_boolean_cond, "x"}, %Evaluator.Error{source: "undefined_var"}] =
             ctx.pending_errors
  end

  # sabotage: `run_partition/2`'s two-element `{:error, reason}` halt arm
  # drops the `{:nested_content, c_index, reason}` wrapper in favor of the
  # bare `reason` (Decision 4) -> this pattern match on the wrapped reason
  # reddens.
  test "a failing partition node returns {:error, ctx, {:nested_content, c_index, reason}}, pending errors intact" do
    m =
      machine()
      |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})

    # Branch 0's non-boolean cond is never selected (treated as false, per
    # 5.9.1) but still records a reason; branch 1 (nil cond) is what
    # actually selects and runs the failing partition - this is what
    # proves the reason recorded *before* selection survives a later
    # failure, per Decision 4/5.
    node =
      if_node([
        branch({:static, "bad"}, [0]),
        branch(nil, [0, 1])
      ])

    assert {:error, ctx, {:nested_content, 1, {:test_content, "boom"}}} =
             ExecutableContent.execute(node, context(m))

    assert ctx.pending_errors == [{:non_boolean_cond, "bad"}]
  end

  # sabotage: `select/3`'s `%If.Branch{cond: nil}` clause is changed to
  # discard the accumulated `reasons` (`{branch, []}` instead of `{branch,
  # reasons}`) -> the inner `<if>`'s own reason (from its own failed first
  # branch) would be dropped before it ever reaches the outer node's
  # `pending_errors`, reddening this test's single-reason assertion.
  test "a nested <if> selects correctly and its reasons accumulate into the outer node's list" do
    inner_if =
      if_node([
        branch({:static, "inner-bad"}, [3]),
        branch(nil, [4])
      ])

    m = machine() |> machine_with_node(2, inner_if)

    outer = if_node([branch(nil, [2])])

    assert {:ok, ctx, [{:log, %Log{label: "c4"}}]} =
             ExecutableContent.execute(outer, context(m))

    assert ctx.pending_errors == [{:non_boolean_cond, "inner-bad"}]
  end
end
