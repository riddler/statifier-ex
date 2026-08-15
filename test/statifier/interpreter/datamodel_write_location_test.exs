defmodule Statifier.Interpreter.DatamodelWriteLocationTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Interpreter.Datamodel
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

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a"/>
  </scxml>
  """

  defp machine, do: compile!(@document)

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  # Builds a MachineState/Predicator.Context pair directly over `datamodel`,
  # sidestepping `Statifier.Interpreter.Datamodel.initialize/1` - every test
  # here wants precise, hand-picked datamodel starting keys, matching
  # `Statifier.Machine.Content.AssignTest`'s own `context/1` helper.
  defp state_and_context(datamodel) do
    machine_state = %{MachineState.new(machine()) | datamodel: datamodel}
    {machine_state, Evaluator.context(machine_state)}
  end

  # sabotage: `write_location/4`'s `write/4` swaps
  # `Predicator.ContextLocation.put/3`'s argument order to
  # `put(path, datamodel, value)` -> this would crash with a
  # FunctionClauseError (`put/3` expects a map first) instead of writing the
  # value, reddening this assertion.
  test "happy path: a flat write lands the value at the top-level key and rebinds the context" do
    {machine_state, context} = state_and_context(%{"x" => nil})

    assert {:ok, new_machine_state, new_context} =
             Datamodel.write_location(machine_state, context, "x", 2)

    assert new_machine_state.datamodel["x"] == 2
    assert Evaluator.evaluate(new_context, compiled_expr("x")) == {:ok, 2}
  end

  # sabotage: `write_location/4`'s `check_system_variable/1` prefix test
  # `String.starts_with?(root, "_")` is replaced with a membership test
  # against `["_event"]` -> `_sessionid` would incorrectly proceed past the
  # guard (and, since it is not a declared datamodel key, would surface as
  # `{:unbound_location, _}` instead), reddening this test's
  # `{:system_variable, _}` match.
  test "a _-rooted path is rejected as a system variable" do
    {machine_state, context} = state_and_context(%{})

    assert {:error, {:system_variable, "_sessionid"}} =
             Datamodel.write_location(machine_state, context, "_sessionid", 1)
  end

  # sabotage: `write_location/4`'s `check_root/3` guard
  # `Map.has_key?(datamodel, List.first(path))` is replaced with `true`
  # unconditionally -> an undeclared root would incorrectly proceed to the
  # write (and, since `put/3` itself vivifies happily, would actually
  # succeed instead of erroring), reddening this test's
  # `{:error, {:unbound_location, _}}` match.
  test "a missing (undeclared) root is rejected without writing" do
    {machine_state, context} = state_and_context(%{})

    assert {:error, {:unbound_location, "foo.bar"}} =
             Datamodel.write_location(machine_state, context, "foo.bar", 1)
  end

  # sabotage: `write_location/4`'s `check_root/3` is changed to check
  # `List.last(path)` instead of `List.first(path)` -> a deep write under a
  # declared root would wrongly report `{:unbound_location, _}` (the last
  # segment, `"c"`, is never a datamodel key), reddening this assertion.
  test "deep vivification creates intermediate maps under a declared root" do
    {machine_state, context} = state_and_context(%{"a" => nil})

    assert {:ok, new_machine_state, new_context} =
             Datamodel.write_location(machine_state, context, "a.b.c", 1)

    assert new_machine_state.datamodel["a"] == %{"b" => %{"c" => 1}}
    assert Evaluator.evaluate(new_context, compiled_expr("a.b.c")) == {:ok, 1}
  end
end
