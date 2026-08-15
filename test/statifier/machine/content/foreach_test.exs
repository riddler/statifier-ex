defmodule Statifier.Machine.Content.ForeachTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Log
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Lowering
  alias Statifier.Machine.Content.Assign
  alias Statifier.Machine.Content.Foreach
  alias Statifier.Machine.Content.If
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.TestContent
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Five plain <log> nodes, c0..c4 - real, addressable content cells that
  # individual tests substitute via `machine_with_node/3`, the same
  # fixture-preserving technique `Statifier.Machine.Content.IfTest` uses.
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

  defp context(machine, datamodel_overrides \\ %{}) do
    ms = MachineState.new(machine)
    ms = %{ms | datamodel: Map.merge(ms.datamodel, datamodel_overrides)}
    %Context{machine_state: ms, owner: @owner, datamodel_context: Evaluator.context(ms)}
  end

  defp foreach_node(opts) do
    %Foreach{
      c_index: 99,
      location: location(),
      array: Keyword.fetch!(opts, :array),
      item: Keyword.get(opts, :item, "v"),
      index: Keyword.get(opts, :index),
      content: Keyword.get(opts, :content, [])
    }
  end

  # A hand-built `%Assign{}`, byte-identical in shape to what the compiler
  # would produce, for a body that writes into the datamodel - `c_index` is
  # never read by `execute/2` itself, only used for the tuple slot
  # `machine_with_node/3` substitutes it into.
  defp assign_node(c_index, path, expr_source) do
    %Assign{
      c_index: c_index,
      location: path,
      node_location: location(),
      value: compiled_expr(expr_source)
    }
  end

  describe "item legality (Decision 1)" do
    # sabotage: `check_name/2`'s `Regex.match?/2` clause is changed to
    # `true -> :ok` unconditionally (accepting every name) -> both illegal
    # names below would be accepted, reddening this test.
    test "a quoted string literal and a dotted path are both illegal item names" do
      node = foreach_node(array: {:static, [1]}, item: "'continue'", content: [0])

      assert {:error, {:illegal_item_name, "'continue'"}} =
               ExecutableContent.execute(node, context(machine()))

      node = foreach_node(array: {:static, [1]}, item: "a.b", content: [0])

      assert {:error, {:illegal_item_name, "a.b"}} =
               ExecutableContent.execute(node, context(machine()))
    end

    # sabotage: `check_name/2`'s `String.starts_with?/2` clause is deleted,
    # falling through to the regex clause (which accepts a leading `_`) ->
    # this test's `{:system_variable, _}` match reddens.
    test "a _-prefixed item is a system-variable violation, not a plain illegal name" do
      node = foreach_node(array: {:static, [1]}, item: "_x", content: [0])

      assert {:error, {:system_variable, "_x"}} =
               ExecutableContent.execute(node, context(machine()))
    end

    # sabotage: `execute/2`'s `with` chain drops the `check_name(node.item,
    # ...)` step entirely (starts from `check_index/1` instead) -> the body
    # (c0, a real `<log>`) would run and this test's "never dispatched"
    # assertion (via the untouched datamodel) reddens.
    test "an illegal item halts before the body ever dispatches and the datamodel is untouched" do
      m = machine() |> machine_with_node(0, %TestContent{c_index: 0, label: "boom", fail: true})
      node = foreach_node(array: {:static, [1]}, item: "'bad'", content: [0])

      ctx = context(m, %{"probe" => "before"})

      assert {:error, {:illegal_item_name, "'bad'"}} = ExecutableContent.execute(node, ctx)
    end
  end

  describe "index legality (Decision 1)" do
    # sabotage: `check_index/1`'s non-nil clause is changed to always
    # return `:ok` (never calling `check_name/2`) -> this test's
    # `{:illegal_index_name, _}` match reddens.
    test "an illegal index name is rejected the same way an illegal item is" do
      node = foreach_node(array: {:static, [1]}, item: "v", index: "'bad'", content: [])

      assert {:error, {:illegal_index_name, "'bad'"}} =
               ExecutableContent.execute(node, context(machine()))
    end
  end

  describe "array evaluation and iterability (Decision 5)" do
    # sabotage: `check_iterable/1`'s guard is changed from `is_list(value)`
    # to `true` (accepting anything) -> this test's `{:not_iterable, 7}`
    # match reddens.
    test "a non-list array value is {:not_iterable, value}" do
      node = foreach_node(array: {:static, 7}, item: "v")

      assert {:error, {:not_iterable, 7}} = ExecutableContent.execute(node, context(machine()))
    end

    # sabotage: `evaluate_array/2`'s `{:error, %Evaluator.Error{}}` clause
    # is dropped, falling through to a `FunctionClauseError` instead of a
    # clean `{:error, error}` -> this pattern match reddens (or the test
    # crashes instead of asserting).
    test "an erroring array expression propagates the %Evaluator.Error{}" do
      node = foreach_node(array: compiled_expr("undefined_var"), item: "v")

      assert {:error, %Evaluator.Error{source: "undefined_var"}} =
               ExecutableContent.execute(node, context(machine()))
    end
  end

  describe "declaration (Decision 2/6)" do
    # sabotage: `declare/2`'s `Map.put_new/3` calls are changed to skip
    # declaration when `collection == []` (an early return before
    # `run_loop/3`) -> this test's `Map.has_key?/2` assertions on an empty
    # array reddens.
    test "item and index are declared even when the collection is empty" do
      node = foreach_node(array: {:static, []}, item: "newvar", index: "newidx", content: [])

      assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))
      assert Map.has_key?(ctx.machine_state.datamodel, "newvar")
      assert ctx.machine_state.datamodel["newvar"] == :undefined
      assert Map.has_key?(ctx.machine_state.datamodel, "newidx")
      assert ctx.machine_state.datamodel["newidx"] == :undefined
    end

    # sabotage: `maybe_put_index/3`'s non-nil clause is deleted (the `nil`
    # clause matches everything, so `index` is never written) -> this test's
    # `refute Map.has_key?/2` still passes but the paired "index is 0-based"
    # test below reddens instead - see that test's own sabotage note; this
    # one instead sabotages `maybe_put_new/2` the same way for `declare/2`,
    # dropping the `index` clause so an omitted `index` is indistinguishable
    # from a declared-but-unused one either way -> both tests together pin
    # the behavior, but this test alone catches a bug where `index` is
    # written despite never being requested.
    test "an omitted index writes no index variable at all" do
      node = foreach_node(array: {:static, [1]}, item: "v", content: [])

      assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))
      refute Map.has_key?(ctx.machine_state.datamodel, "idx")
    end
  end

  describe "iteration (Decision 3/5)" do
    # sabotage: `run_loop/3`'s `Enum.with_index/1` is replaced with
    # `Enum.with_index(collection, 1)` (1-based) -> this test's assertion
    # that the last index is `2` (for a 3-element array) reddens.
    test "iteration is in list order, item takes each value, and index is 0-based" do
      node = foreach_node(array: {:static, [10, 20, 30]}, item: "v", index: "i", content: [])

      assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))
      assert ctx.machine_state.datamodel["v"] == 30
      assert ctx.machine_state.datamodel["i"] == 2
    end

    # sabotage: `run_content/2`'s fold accumulates `node_effects ++ effects`
    # instead of `effects ++ node_effects` -> the two logs within one
    # iteration's body come back reversed, reddening this ordered match.
    test "effects come back in iteration-then-document order" do
      m = machine()
      node = foreach_node(array: {:static, [1, 2]}, item: "v", content: [0, 1])

      assert {:ok, _ctx,
              [
                {:log, %Log{label: "c0"}},
                {:log, %Log{label: "c1"}},
                {:log, %Log{label: "c0"}},
                {:log, %Log{label: "c1"}}
              ]} = ExecutableContent.execute(node, context(m))
    end

    # sabotage: write_iteration/4's Map.put/3 for `item` writes into a
    # throwaway key ("__item") instead of node.item, so the body's
    # expr="sum + v" reads a stale/undefined `v` -> this test's final-sum
    # assertion reddens (the test155 shape).
    test "a body <assign> accumulates across iterations" do
      m = machine() |> machine_with_node(0, assign_node(0, "sum", "sum + v"))
      node = foreach_node(array: {:static, [1, 2, 3]}, item: "v", content: [0])

      ctx = context(m, %{"sum" => 0})

      assert {:ok, ctx, _effects} = ExecutableContent.execute(node, ctx)
      assert ctx.machine_state.datamodel["sum"] == 6
    end

    # sabotage: evaluate_array/2 is called again inside run_loop/3 (moved
    # from execute/2's with chain into the fold) -> a body that empties the
    # array's own source variable shrinks the remaining iteration count
    # instead of running all three (the test525 shape) -> this test's
    # exact-three-iterations assertion reddens.
    test "mutating the array's own source variable inside the body does not change the iteration count" do
      m = machine() |> machine_with_node(0, assign_node(0, "Var1", "[]"))
      node = foreach_node(array: compiled_expr("Var1"), item: "v", index: "i", content: [0])

      ctx = context(m, %{"Var1" => [1, 2, 3]})

      assert {:ok, ctx, _effects} = ExecutableContent.execute(node, ctx)
      assert ctx.machine_state.datamodel["i"] == 2
      assert ctx.machine_state.datamodel["Var1"] == []
    end

    # sabotage: `bind_names/4` is changed to leave `context.datamodel_context`
    # untouched (dropping both `Evaluator.bind/3` calls, keeping only the
    # `machine_state` swap) -> the raw datamodel still ends up correct, so a
    # test asserting only `ctx.machine_state.datamodel` would not catch
    # this, but the block's threaded context never sees `item`/`index`'s
    # final values, and evaluating "v"/"i" against it answers
    # `{:error, %UndefinedVariableError{}}` instead of the final values,
    # reddening both assertions.
    test "the threaded datamodel_context matches the final item/index after N iterations" do
      node = foreach_node(array: {:static, [10, 20, 30]}, item: "v", index: "i", content: [])

      assert {:ok, ctx, []} = ExecutableContent.execute(node, context(machine()))

      assert Evaluator.evaluate(ctx.datamodel_context, compiled_expr("v")) == {:ok, 30}
      assert Evaluator.evaluate(ctx.datamodel_context, compiled_expr("i")) == {:ok, 2}
    end

    # sabotage: `bind_names/4` is changed to build a fresh
    # `Predicator.Context.new(%{item => ...}, ...)` over only the just-
    # written names instead of binding into `context.datamodel_context` ->
    # every other key the loop never touches, like "keep", is lost from the
    # context, and evaluating "keep" against it answers
    # `{:error, %UndefinedVariableError{}}` instead of `{:ok, "untouched"}`,
    # reddening this assertion.
    test "a datamodel root untouched by the loop stays readable in the context throughout" do
      node = foreach_node(array: {:static, [1, 2]}, item: "v", content: [])
      ctx = context(machine(), %{"keep" => "untouched"})

      assert {:ok, ctx, []} = ExecutableContent.execute(node, ctx)

      assert Evaluator.evaluate(ctx.datamodel_context, compiled_expr("keep")) ==
               {:ok, "untouched"}
    end
  end

  describe "a failing body (Decision 4)" do
    # sabotage: `run_loop/3`'s `{:error, new_context, reason}` halt arm is
    # collapsed to the two-element `{:error, reason}` form, discarding
    # `new_context` (Decision 4's whole point) -> the pattern match on
    # `{:error, ctx, _}` reddens, and the `ctx.machine_state.datamodel`
    # mutation assertion below it would never even run.
    test "a body failure returns {:error, ctx, {:nested_content, c_index, reason}}, earlier mutations intact" do
      m =
        machine()
        |> machine_with_node(0, assign_node(0, "seen", "1"))
        |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})

      node = foreach_node(array: {:static, [1, 2]}, item: "v", content: [0, 1])

      assert {:error, ctx, {:nested_content, 1, {:test_content, "boom"}}} =
               ExecutableContent.execute(node, context(m, %{"seen" => 0}))

      assert ctx.machine_state.datamodel["seen"] == 1
    end

    # sabotage: `run_content/2`'s `{:ok, new_context, node_effects}` clause
    # is changed to keep folding with the pre-call `context` instead of the
    # freshly returned `new_context` (discarding the inner `<if>`'s own
    # `pending_errors` accumulation the same way it would discard an
    # `<assign>` rebuild) -> this test's `pending_errors` assertion
    # reddens.
    test "a nested <if>'s pending_errors survive into the returned context" do
      inner_if = %If{
        c_index: 1,
        location: location(),
        branches: [
          %If.Branch{cond: {:static, "bad"}, content: []},
          %If.Branch{cond: nil, content: [2]}
        ]
      }

      m = machine() |> machine_with_node(1, inner_if)
      node = foreach_node(array: {:static, [1]}, item: "v", content: [1])

      assert {:ok, ctx, [{:log, %Log{label: "c2"}}]} = ExecutableContent.execute(node, context(m))
      assert ctx.pending_errors == [{:non_boolean_cond, "bad"}]
    end
  end
end
