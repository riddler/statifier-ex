defmodule Statifier.Machine.Content.ScriptTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Lowering
  alias Statifier.Machine.Content.Script
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

  defp program(source) do
    {:ok, compiled} = Predicator.compile_program_with_positions(source)
    {:program, compiled, source}
  end

  # Builds a %Context{} directly over `datamodel`, sidestepping
  # Statifier.Interpreter.Datamodel.initialize/1 - every test here wants
  # precise, hand-picked datamodel starting keys, the same technique
  # `assign_test.exs`'s own `context/1` uses.
  defp context(datamodel) do
    ms = %{MachineState.new(machine()) | datamodel: datamodel}
    %Context{machine_state: ms, owner: @owner, datamodel_context: Evaluator.context(ms)}
  end

  defp script(program) do
    %Script{c_index: 0, program: program, node_location: location()}
  end

  # sabotage: `execute/2`'s `%Script{program: program}` clause calls
  # `Evaluator.execute(machine_state, program)` with `context.machine_state`
  # swapped for a freshly built `MachineState.new(machine())` (ignoring the
  # datamodel the caller actually seeded) -> the write would land against an
  # empty datamodel instead of the seeded one, and this assertion's exact
  # value would still coincidentally match for a single write like this one,
  # so the mutation that actually reddens it is `rebind/2` returning the
  # *original* `context` unchanged instead of the one carrying the new
  # `machine_state` - the datamodel read below would then see the pre-run
  # value.
  test "a successful program's writes land on the returned context's machine_state" do
    ctx = context(%{"x" => nil})
    node = script(program("x = 1;"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["x"] == 1
  end

  # sabotage: `execute/2`'s `{:invalid, error}` clause is dropped, letting
  # the general `%Script{program: program}` clause match `{:invalid, _}`
  # too and hand it straight to `Evaluator.execute/2`, which has no clause
  # for that shape -> this test reddens with a FunctionClauseError instead
  # of the clean `{:error, ^compiler_error}` match.
  test "a program that failed to compile ({:invalid, _}) short-circuits without evaluating" do
    ctx = context(%{"x" => nil})

    compiler_error = %Statifier.Compiler.Error{
      reason: :fake,
      message: "boom",
      location: location()
    }

    node = script({:invalid, compiler_error})

    assert {:error, ^compiler_error} = ExecutableContent.execute(node, ctx)
  end

  # sabotage: `execute/2`'s `{:error, machine_state, error}` clause is
  # changed to return `{:error, error}` (the two-element leaf form) instead
  # of `{:error, rebind(context, machine_state), error}` -> the partial
  # write this test asserts on would be discarded along with the context,
  # reddening the datamodel assertion below (ADR-0026 decision 1: a
  # mid-program failure keeps the earlier write).
  test "a mid-program failure returns the three-element form, keeping the earlier write" do
    ctx = context(%{"x" => nil, "y" => nil})
    node = script(program("x = 1; y = nope + 1;"))

    assert {:error, new_ctx, %Evaluator.Error{}} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["x"] == 1
    assert new_ctx.machine_state.datamodel["y"] == nil
  end

  # AC (Decision 2): a script may create a new top-level root no
  # `<datamodel>` declared, unlike `<assign>`'s `check_root/3` - the
  # moduledoc's stated asymmetry, pinned behaviorally.
  #
  # sabotage: `Evaluator.execute/2`'s `partition_changed_roots/2` is changed
  # to only ever consider keys already present in `before_data` (dropping
  # the "absent root diffs as changed" property) -> a program-created root
  # would never be merged into `machine_state.datamodel`, reddening this
  # test's assertion that `Var1` exists after the run.
  test "a program may create a new top-level root, unlike <assign>" do
    ctx = context(%{})
    node = script(program("Var1 = 1;"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)
    assert new_ctx.machine_state.datamodel["Var1"] == 1
  end

  # sabotage: `rebind/2` is changed to set `machine_state` but leave
  # `datamodel_context` as the caller's original (pre-write) value instead
  # of rebuilding it with `Evaluator.context(machine_state)` -> evaluating
  # the newly written variable against the returned `datamodel_context`
  # would fail as unbound, reddening this test.
  test "the returned context's datamodel_context evaluates the newly written variable" do
    ctx = context(%{"x" => nil})
    node = script(program("x = 42;"))

    assert {:ok, new_ctx, []} = ExecutableContent.execute(node, ctx)

    {:ok, compiled} = Predicator.compile_with_spans("x")
    assert Evaluator.evaluate(new_ctx.datamodel_context, {:compiled, compiled, "x"}) == {:ok, 42}
  end
end
