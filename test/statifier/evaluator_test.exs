defmodule Statifier.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Predicator.Errors.EvaluationError
  alias Predicator.Errors.TypeMismatchError
  alias Predicator.Errors.UndefinedVariableError
  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Evaluator.Error
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <state id="s1"/>
      <state id="s2"/>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp machine, do: compile!(@document)
  defp idx(machine, id), do: Machine.index(machine, id) |> elem(1)

  defp new_machine_state(opts \\ []) do
    machine = machine()
    ms = MachineState.new(machine, opts)

    case Keyword.get(opts, :configuration) do
      nil -> ms
      configuration -> %{ms | configuration: configuration}
    end
  end

  # `MachineState.new/2` has no `:configuration` option, so this builds one
  # directly with `s1` active - the fixture every `In/1` test starts from.
  defp machine_state_with_s1_active do
    machine = machine()
    ms = MachineState.new(machine)
    %{ms | configuration: MapSet.new([idx(machine, "s1")])}
  end

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  describe "evaluate/2 - {:static, v}" do
    # sabotage: `evaluate/2`'s static clause routes the value through
    # `Predicator.evaluate/3` instead of returning it untouched -> a static
    # `nil` comes back normalized to `:undefined` instead of `nil`, and this
    # assertion reddens.
    test "returns the value untouched, with no predicator normalization" do
      context = Evaluator.context(new_machine_state())

      assert Evaluator.evaluate(context, {:static, nil}) == {:ok, nil}
      assert Evaluator.evaluate(context, {:static, %{a: 1}}) == {:ok, %{a: 1}}
      assert Evaluator.evaluate(context, {:static, :some_atom}) == {:ok, :some_atom}
    end
  end

  describe "evaluate/2 - {:compiled, _, _}" do
    # sabotage: `evaluate/2`'s compiled clause always returns `{:ok, false}`
    # regardless of `Predicator.evaluate/3`'s result -> this assertion
    # reddens because `score > 80` is true against the bound datamodel.
    test "evaluates true against a bound datamodel" do
      ms = new_machine_state(datamodel: %{"score" => 85})
      context = Evaluator.context(ms)

      assert Evaluator.evaluate(context, compiled_expr("score > 80")) == {:ok, true}
    end

    # sabotage: `evaluate/2`'s compiled clause always returns `{:ok, true}`
    # regardless of `Predicator.evaluate/3`'s result -> this assertion
    # reddens because `score < 80` is false against the bound datamodel.
    test "evaluates false against a bound datamodel" do
      ms = new_machine_state(datamodel: %{"score" => 85})
      context = Evaluator.context(ms)

      assert Evaluator.evaluate(context, compiled_expr("score < 80")) == {:ok, false}
    end

    # sabotage: `context/1` builds the context with `on_unbound: :undefined`
    # instead of `:error` -> `score OR true` no longer fails on the unbound
    # load; three-valued logic absorbs `score`'s `:undefined` and the whole
    # expression evaluates to `{:ok, true}` instead of erroring, so the
    # pattern match below fails to match an `{:error, _}` tuple. (A bare
    # `score` alone does not distinguish the two policies here - predicator
    # reports the same unbound-variable error either way when the *whole*
    # expression's result is `:undefined` - so this test deliberately uses
    # an expression whose result differs by policy.)
    test "an unbound root variable returns an error with a non-nil span" do
      context = Evaluator.context(new_machine_state())

      assert {:error,
              %Error{
                source: "score OR true",
                error: %UndefinedVariableError{variable: "score"},
                span: span
              }} =
               Evaluator.evaluate(context, compiled_expr("score OR true"))

      refute is_nil(span)
    end

    # sabotage: `evaluate/2`'s compiled clause returns `{:ok, error}` instead
    # of `{:error, Error.new(source, error)}` on predicator's error branch ->
    # this pattern match fails because the outer tag is `:ok`, not `:error`.
    test "a type mismatch returns an error carrying predicator's TypeMismatchError" do
      context = Evaluator.context(new_machine_state())

      assert {:error, %Error{error: %TypeMismatchError{}}} =
               Evaluator.evaluate(context, compiled_expr("1 * \"a\""))
    end

    # sabotage: `in_function/1`'s matched-id branch is swapped to always
    # return `{:ok, false}` -> `In("s1")` against a configuration containing
    # `s1` comes back false, and this assertion reddens.
    test "In/1 is true for a state in the configuration" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('s1')")) == {:ok, true}
    end

    # sabotage: `in_function/1`'s matched-id branch is swapped to always
    # return `{:ok, true}` -> `In("s2")` against a configuration that does
    # not contain `s2` comes back true, and this assertion reddens.
    test "In/1 is false for a declared state that is not in the configuration" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('s2')")) == {:ok, false}
    end

    # sabotage: `in_function/1`'s `:error` branch (from `Machine.index/2`) is
    # changed to `{:ok, true}` -> `In/1` on an id the document never
    # declared comes back true, and this assertion reddens. This is the only
    # test that reaches that branch - `Machine.index/2` returns `:error` only
    # for an id absent from `id_to_index`.
    test "In/1 is false for an id the machine never declared" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('no-such-state')")) == {:ok, false}
    end

    # sabotage: `in_function/1` is changed to stash `configuration` in a
    # process-dictionary slot shared across every `context/1` call instead of
    # closing over it locally -> building `ctx2` overwrites the slot `ctx1`'s
    # closure also reads from, so re-evaluating `in_s2` against `ctx1` after
    # `ctx2` exists answers against `s2`'s configuration instead of `s1`'s,
    # and the final assertion reddens.
    test "the built context is a snapshot: a later configuration change needs a new context/1 call" do
      machine = machine()
      ms = MachineState.new(machine)
      ms_s1 = %{ms | configuration: MapSet.new([idx(machine, "s1")])}
      ctx1 = Evaluator.context(ms_s1)
      in_s2 = compiled_expr("In('s2')")

      assert Evaluator.evaluate(ctx1, in_s2) == {:ok, false}

      ms_s2 = %{ms | configuration: MapSet.new([idx(machine, "s2")])}
      ctx2 = Evaluator.context(ms_s2)

      assert Evaluator.evaluate(ctx2, in_s2) == {:ok, true}
      # ctx1 was built before the move and still answers against the old
      # configuration - it is not rebuilt by the mutation on `ms_s2`.
      assert Evaluator.evaluate(ctx1, in_s2) == {:ok, false}
    end

    # sabotage: `evaluate/2`'s compiled clause matches `{:error, error}` and
    # instead raises via `error.error` (a bare `raise error` on the
    # predicator error struct) -> `Predicator.evaluate/3`'s own division-by-
    # zero error propagates as a raised exception, and the surrounding
    # `assert {:error, _} = ...` crashes the test process rather than
    # matching.
    test "never raises: a division-by-zero expression returns an error tuple" do
      context = Evaluator.context(new_machine_state())

      assert {:error, %Error{error: %EvaluationError{reason: "division_by_zero"}}} =
               Evaluator.evaluate(context, compiled_expr("1 / 0"))
    end
  end
end
