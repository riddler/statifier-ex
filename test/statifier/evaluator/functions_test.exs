defmodule Statifier.Evaluator.FunctionsTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Machine, Parser, Validator}
  alias Statifier.Evaluator.Functions

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <state id="s1"/>
      <state id="s2"/>
  </scxml>
  """

  defp compile! do
    {:ok, root} = Parser.parse(@document)
    {:ok, document} = Lowering.lower(root, @document)
    {:ok, document, _warnings} = Validator.validate(document, @document)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp idx(machine, id), do: Machine.index(machine, id) |> elem(1)

  describe "functions/0" do
    # sabotage: `functions/0` returns `%{}` instead of `@functions` -> the
    # `Predicator.FunctionProvider` behaviour has no entry to validate against
    # `base_context/0`'s hand-shaped one, and the agreement assertion below
    # fails to find "In" in `functions/0`'s map.
    test "declares In/1, dispatched to in_state/2" do
      assert Functions.functions() == %{"In" => {1, :in_state}}
    end
  end

  describe "base_context/0" do
    # sabotage: `@base_context` is built with `functions: %{}` instead of
    # `functions: %{"In" => {1, {__MODULE__, :in_state}}}` -> "In" is absent
    # from the resolved map and this assertion reddens.
    test "resolves In/1 to {Statifier.Evaluator.Functions, :in_state}, agreeing with functions/0" do
      context = Functions.base_context()

      assert context.functions["In"] == {1, {Statifier.Evaluator.Functions, :in_state}}
      assert {arity, :in_state} = Functions.functions()["In"]
      assert {^arity, {Statifier.Evaluator.Functions, :in_state}} = context.functions["In"]
    end

    # sabotage: `@base_context` is built with `on_unbound: :undefined`
    # instead of `on_unbound: :error` -> this assertion reddens.
    test "is a constant: empty data, nil host, on_unbound: :error" do
      context = Functions.base_context()

      assert context.data == %{}
      assert context.host == nil
      assert context.on_unbound == :error
      assert Functions.base_context() == context
    end
  end

  describe "in_state/2" do
    # sabotage: `in_state/2`'s matched-id branch is swapped to always return
    # `{:ok, false}` -> a state present in the configuration answers false,
    # reddening this assertion.
    test "true for a state in the configuration" do
      machine = compile!()
      configuration = MapSet.new([idx(machine, "s1")])
      context = Predicator.Context.put_host(Functions.base_context(), {machine, configuration})

      assert Functions.in_state(["s1"], context) == {:ok, true}
    end

    # sabotage: `in_state/2`'s matched-id branch is swapped to always return
    # `{:ok, true}` -> a declared state absent from the configuration answers
    # true, reddening this assertion.
    test "false for a declared state not in the configuration" do
      machine = compile!()
      configuration = MapSet.new([idx(machine, "s1")])
      context = Predicator.Context.put_host(Functions.base_context(), {machine, configuration})

      assert Functions.in_state(["s2"], context) == {:ok, false}
    end

    # sabotage: the `:error` branch (from `Machine.index/2`) is changed to
    # `{:ok, true}` -> an id the document never declared answers true,
    # reddening this assertion.
    test "false for an id the machine never declared" do
      machine = compile!()
      configuration = MapSet.new([idx(machine, "s1")])
      context = Predicator.Context.put_host(Functions.base_context(), {machine, configuration})

      assert Functions.in_state(["no-such-state"], context) == {:ok, false}
    end
  end
end
