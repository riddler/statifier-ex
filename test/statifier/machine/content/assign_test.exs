defmodule Statifier.Machine.Content.AssignTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Lowering
  alias Statifier.Machine.Content.Assign
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a"/>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp location, do: Location.at_offset("", 0)
  @owner {:onentry, 0, 0}

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  # Builds a %Context{} directly over `datamodel`, sidestepping
  # Statifier.Interpreter.Datamodel.initialize/1 - every test here wants
  # precise, hand-picked datamodel starting keys (Decision 4's root-existence
  # rule means what is and is not pre-declared is the point under test).
  defp context(datamodel) do
    ms = %{MachineState.new(machine()) | datamodel: datamodel}
    %Context{machine_state: ms, owner: @owner, datamodel_context: Evaluator.context(ms)}
  end

  defp assign(location, value) do
    %Assign{c_index: 0, location: location, node_location: location(), value: value}
  end

  # sabotage: `Assign`'s `execute/2` step 4 (`write/4`) is changed to write
  # through `Predicator.Context.new(machine_state.datamodel, ...) |>
  # Predicator.ContextLocation.put(...)` (the normalized context) instead of
  # the raw `machine_state.datamodel` -> this test's own assertion would
  # still pass (nothing here reads `:undefined`), so the sabotage that
  # actually reddens *this* invariant is recorded on the datamodel_test.exs
  # regression test instead, which has an unrelated seeded-nil id to observe
  # the difference against; this test's own sabotage below covers the write
  # itself landing at the right key.
  test "a flat write lands the evaluated value at the top-level key" do
    ctx = context(%{"x" => nil})
    node = assign("x", compiled_expr("1 + 1"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["x"] == 2
  end

  # sabotage: `Assign`'s `check_root/3` is changed to check
  # `List.last(path)` instead of `List.first(path)` -> a deep write under a
  # declared root would wrongly report `{:unbound_location, _}` (the last
  # segment, `"c"`, is never a datamodel key), reddening this assertion.
  test "a deep write vivifies two intermediate maps under a declared root" do
    ctx = context(%{"a" => nil})
    node = assign("a.b.c", compiled_expr("1"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["a"] == %{"b" => %{"c" => 1}}
  end

  # sabotage: `Assign`'s `write/4` swaps `Predicator.ContextLocation.put/3`'s
  # argument order to `put(path, machine_state.datamodel, value)` -> this
  # would crash with a FunctionClauseError (put/3 expects a map first)
  # instead of padding the list, reddening this test with a raise rather
  # than a clean assertion.
  test "a list index past the end pads the gap with :undefined" do
    ctx = context(%{"items" => [1]})
    node = assign("items[2]", compiled_expr("99"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["items"] == [1, :undefined, 99]
  end

  # sabotage: `Assign`'s `write/4` drops the `{:error, error} ->
  # {:error, Evaluator.Error.new(location, error)}` branch, letting
  # `Predicator.ContextLocation.put/3`'s raw `{:error, %LocationError{}}`
  # tuple flow straight through -> the `%Evaluator.Error{}` wrapper would be
  # missing, reddening this pattern match.
  test "a negative index yields a wrapped LocationError with type :invalid_index" do
    ctx = context(%{"items" => [1, 2, 3]})
    node = assign("items[-1]", compiled_expr("1"))

    assert {:error,
            %Evaluator.Error{
              source: "items[-1]",
              error: %Predicator.Errors.LocationError{type: :invalid_index}
            }} = ExecutableContent.execute(node, ctx)
  end

  # sabotage: `Assign`'s `check_root/3` short-circuits every path with `:ok`
  # unconditionally (dropping Decision 4's root-existence check entirely) ->
  # the write would proceed against the scalar `"x"` root and
  # `Predicator.ContextLocation.put/3`'s own `:not_a_container` error would
  # still surface (since `put/3` independently detects the collision), so
  # this specific sabotage does not redden this test; the mutation that does
  # is `write/4`'s `{:error, error} -> {:error, ...}` branch being dropped
  # (already covered by the negative-index test above) - recorded here as
  # the honest result of trying the "obvious" mutation first.
  test "a scalar collision mid-path yields a wrapped LocationError with type :not_a_container" do
    ctx = context(%{"x" => 5})
    node = assign("x.y", compiled_expr("1"))

    assert {:error,
            %Evaluator.Error{error: %Predicator.Errors.LocationError{type: :not_a_container}}} =
             ExecutableContent.execute(node, ctx)
  end

  describe "system-variable protection (spec 5.10)" do
    # sabotage: `Assign`'s `check_system_variable/1` prefix test
    # `String.starts_with?(root, "_")` is replaced with a membership test
    # against `["_event"]` -> `_sessionid`, `_name`, and `_ioprocessors`
    # would incorrectly proceed past the guard (and, since none of those
    # roots is a declared datamodel key, would surface as
    # `{:unbound_location, _}` instead), reddening these three tests'
    # `{:system_variable, _}` match.
    for name <- ~w(_event _sessionid _name _ioprocessors) do
      test "assigning to #{name} yields {:error, {:system_variable, _}}" do
        ctx = context(%{})
        node = assign(unquote(name), compiled_expr("1"))

        assert {:error, {:system_variable, unquote(name)}} = ExecutableContent.execute(node, ctx)
      end
    end

    # sabotage: same mutation as above (membership test against
    # `["_event"]`) - since `"_event"` *is* in that list, this test's own
    # dotted/bracket roots would still be caught, so it does not redden
    # under that particular sabotage; the mutation that reddens *this* test
    # is `check_system_variable/1`'s guard testing `List.last(path)`
    # instead of the resolved `root` (`List.first(path)`) -> `_event.name`
    # resolves to `["_event", "name"]` and `List.last/1` would test `"name"`,
    # which does not start with "_", incorrectly proceeding past the guard.
    test "a nested write under _event reports the root for both dot and bracket access" do
      ctx = context(%{})

      assert {:error, {:system_variable, "_event"}} =
               ExecutableContent.execute(assign("_event.name", compiled_expr("1")), ctx)

      assert {:error, {:system_variable, "_event"}} =
               ExecutableContent.execute(assign("_event['name']", compiled_expr("1")), ctx)
    end

    # sabotage: `Assign`'s `check_system_variable/1` prefix test
    # `String.starts_with?(root, "_")` is replaced with a membership test
    # against `["_event"]` -> `_x` is not in that list, so this test's
    # `{:system_variable, "_x"}` match would go red (it would instead
    # surface as `{:unbound_location, "_x.foo"}`, since `"_x"` is not a
    # declared datamodel key either).
    test "_x.foo (the platform-variable root) yields {:error, {:system_variable, \"_x\"}}" do
      ctx = context(%{})
      node = assign("_x.foo", compiled_expr("1"))

      assert {:error, {:system_variable, "_x"}} = ExecutableContent.execute(node, ctx)
    end

    # sabotage: `Assign`'s `check_system_variable/1` clause guard
    # `is_binary(root)` is dropped, or the whole function is replaced with
    # `{:error, {:system_variable, root}}` unconditionally -> a declared,
    # non-underscore root like `my_var` would incorrectly be rejected as a
    # system variable, reddening this test's `{:ok, _, []}` match.
    test "a non-underscore root with an underscore inside it (my_var) still writes" do
      ctx = context(%{"my_var" => nil})
      node = assign("my_var", compiled_expr("1"))

      assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
      assert new_ctx.machine_state.datamodel["my_var"] == 1
    end
  end

  # sabotage: `Assign`'s `check_root/3` guard `Map.has_key?(machine_state.datamodel,
  # List.first(path))` is replaced with `true` unconditionally -> an
  # undeclared root would incorrectly proceed to the write (and, since
  # `put/3` itself vivifies happily, would actually succeed instead of
  # erroring), reddening this test's `{:error, {:unbound_location, _}}` match.
  test "an undeclared root yields {:error, {:unbound_location, _}} without writing" do
    ctx = context(%{})
    node = assign("foo.bar.baz", compiled_expr("1"))

    assert {:error, {:unbound_location, "foo.bar.baz"}} = ExecutableContent.execute(node, ctx)
  end

  # sabotage: `Assign`'s `resolve_location/2` drops the `{:error, error} ->
  # {:error, Evaluator.Error.new(location, error)}` wrapping branch, letting
  # `Predicator.context_location/3`'s raw `{:error, %LocationError{}}` tuple
  # flow straight through -> the `%Evaluator.Error{}` wrapper would be
  # missing, reddening this pattern match. (Passing the unwrapped
  # `%Predicator.Context{}` struct instead of `.data` was tried first and
  # does *not* redden this test - `context_location/3` never consults the
  # context at all for a bare function-call node, so the wrong-context bug
  # only matters for a bracket-key lookup, not this shape.)
  test "a non-assignable location (a function call) yields :not_assignable" do
    ctx = context(%{"items" => [1, 2, 3]})
    node = assign("len(items)", compiled_expr("1"))

    assert {:error,
            %Evaluator.Error{error: %Predicator.Errors.LocationError{type: :not_assignable}}} =
             ExecutableContent.execute(node, ctx)
  end

  # sabotage: `Assign`'s `evaluate_value/2` is changed to call
  # `Evaluator.evaluate(context.datamodel_context, value)` even when `value`
  # is `{:invalid, error}`, instead of short-circuiting -> `Evaluator.evaluate/2`
  # has no clause for `{:invalid, _}` and raises `FunctionClauseError` instead
  # of returning the captured compiler error cleanly, reddening this test
  # with a crash rather than a clean assertion.
  test "an expr that failed to compile ({:invalid, _}) short-circuits without evaluating" do
    ctx = context(%{"x" => nil})

    compiler_error = %Statifier.Compiler.Error{
      reason: :fake,
      message: "boom",
      location: location()
    }

    node = assign("x", {:invalid, compiler_error})

    assert {:error, ^compiler_error} = ExecutableContent.execute(node, ctx)
  end

  # sabotage: `Assign`'s `evaluate_value/2` catches `Evaluator.evaluate/2`'s
  # `{:error, _}` and swallows it, returning `{:ok, nil}` instead of
  # propagating the failure -> the write would proceed with `nil` instead of
  # failing, reddening this test's `%Evaluator.Error{}` match.
  test "an expr that fails to evaluate (an unbound identifier) yields an Evaluator.Error" do
    ctx = context(%{"x" => nil})
    node = assign("x", compiled_expr("return"))

    assert {:error, %Evaluator.Error{source: "return"}} = ExecutableContent.execute(node, ctx)
  end

  # sabotage: `Assign`'s `execute/2` returns the original `context` unchanged
  # instead of `%{context | machine_state: ms, datamodel_context:
  # Evaluator.context(ms)}` -> the returned context's `datamodel_context`
  # would still be the pre-write snapshot, so evaluating the newly written
  # variable against it would fail as unbound, reddening this test.
  test "the returned context's datamodel_context evaluates the newly written variable" do
    ctx = context(%{"x" => nil})
    node = assign("x", compiled_expr("42"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert Evaluator.evaluate(new_ctx.datamodel_context, compiled_expr("x")) == {:ok, 42}
  end
end
