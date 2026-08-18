defmodule Statifier.Parser.LocationSpanResolutionTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler.Error, as: CompilerError
  alias Statifier.Compiler.Expressions
  alias Statifier.{Evaluator, Parser}
  alias Statifier.Parser.{DOM, Location}

  # Phase 1's `resolve_span/4` tests feed hand-written spans. These prove the
  # same composition against a span predicator actually produced, reached
  # through the real parse -> compile -> evaluate path a diagnostic renderer
  # would use.

  defp cond_attribute(source) do
    assert {:ok, root} = Parser.parse(source)
    DOM.attribute(root, "cond")
  end

  describe "an UndefinedVariableError span, reached through compile and evaluate" do
    # sabotage: the reference-consuming branch of `next_unit/2` slices the raw
    # rest by `byte_size(decoded)` instead of `byte_size(token)` -> the walk
    # desyncs past the `&lt;` reference -> this test reddens (slice returns
    # the whole attribute value instead of "score")
    test "resolves the real UndefinedVariableError span to the raw source slice" do
      source = ~s(<edge cond="1 &lt; score"/>)
      attribute = cond_attribute(source)

      assert {:ok, expr} =
               Expressions.compile(attribute.value, {:transition, 0}, attribute.value_location)

      context = Predicator.Context.new(%{}, on_unbound: :error)

      assert {:error, %Evaluator.Error{span: span, source: expr_source}} =
               Evaluator.evaluate(context, expr)

      resolved = Location.resolve_span(attribute.value_location, span, expr_source, source)

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: `expanded_advance/2`'s `"\n"` clause returns `{line + 1,
    # column}` instead of `{line + 1, 1}` -> the expanded cursor's column
    # never resets after the character-reference line break -> this test
    # reddens (the evaluator's line-2 span target is never reached, so the
    # span clamps to the whole attribute value instead of "score")
    test "a failing identifier after a &#10; resolves through the line shift" do
      source = ~s(<edge cond="1 &lt;&#10;score"/>)
      attribute = cond_attribute(source)

      assert {:ok, expr} =
               Expressions.compile(attribute.value, {:transition, 0}, attribute.value_location)

      context = Predicator.Context.new(%{}, on_unbound: :error)

      assert {:error, %Evaluator.Error{span: span, source: expr_source}} =
               Evaluator.evaluate(context, expr)

      # value expands to "1 <\nscore" - the undefined variable is on
      # expanded line 2, a line the raw source (single physical line) does
      # not have.
      assert {{2, _start_column}, {2, _end_column}} = span

      resolved = Location.resolve_span(attribute.value_location, span, expr_source, source)

      assert Location.slice(resolved, source) == "score"
    end
  end

  describe "a compile-time ParseError span" do
    # sabotage: `next_unit_plain/2`'s `raw_cp == value_cp` guard inverted to
    # `raw_cp != value_cp` -> the plain-text case never matches, so the walk
    # desyncs immediately -> this test reddens (slice returns the whole
    # attribute value, "score > > 5", instead of ">")
    test "resolves a malformed cond's ParseError span, not an evaluator error" do
      source = ~s(<edge cond="score > > 5"/>)
      attribute = cond_attribute(source)

      assert {:error,
              %CompilerError{
                reason: {:expression_compile_error, {:transition, 0}, expr_source, parse_error}
              }} =
               Expressions.compile(attribute.value, {:transition, 0}, attribute.value_location)

      resolved =
        Location.resolve_span(attribute.value_location, parse_error.span, expr_source, source)

      assert Location.slice(resolved, source) == ">"
    end
  end
end
