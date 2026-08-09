defmodule Statifier.Compiler.ExpressionsTest do
  use ExUnit.Case, async: true

  alias Predicator.Errors.ParseError
  alias Statifier.Compiler.Error
  alias Statifier.Compiler.Expressions
  alias Statifier.Parser.Location

  # Every call below gets its own offset, so a bug that reused one call's
  # location for another would surface as a location mismatch rather than
  # passing by coincidence (test/statifier/document_test.exs's `loc/1`).
  defp loc(offset) do
    %Location{
      start_line: 1,
      start_column: offset + 1,
      start_offset: offset,
      end_line: 1,
      end_column: offset + 2,
      end_offset: offset + 1
    }
  end

  # sabotage: swap compile_with_spans/1 for compile_with_positions/1 in
  # Expressions.compile/3 -> the positions table holds points ({l, c}) again
  # instead of spans ({{l, c}, {l, c}}), and this test goes red
  test "compile/3 compiles a valid expression with a span table, not point positions" do
    assert {:ok, {:compiled, %Predicator.Compiled{} = compiled, "score > 85"}} =
             Expressions.compile("score > 85", {:transition, 0}, loc(0))

    refute compiled.positions == %{}

    # ADR-0014 item 1, mechanically checked: every stored position is a
    # two-element span {start, end}, each itself a {line, column} point -
    # not a bare {line, column} point position.
    for {_instruction_index, position} <- compiled.positions do
      assert {{start_line, start_column}, {end_line, end_column}} = position
      assert is_integer(start_line) and is_integer(start_column)
      assert is_integer(end_line) and is_integer(end_column)
    end
  end

  # sabotage: change static/1 to always return {:static, nil} -> red
  test "static/1 wraps a literal value with no expression to evaluate" do
    assert {:static, "hello"} = Expressions.static("hello")
    assert {:static, 42} = Expressions.static(42)
  end

  # sabotage: in Error.expression_compile_error/4, drop the interpolated
  # `#{inspect(source)}` from the message string -> the message no longer
  # contains the source, and this test goes red
  test "compile/3 reports an invalid expression naming the source, the caller's location, and predicator's position" do
    location = loc(17)

    assert {:error, %Error{} = error} = Expressions.compile("score >", {:content, 3}, location)

    assert error.location == location
    assert error.message =~ "score >"

    assert {:expression_compile_error, {:content, 3}, "score >",
            %ParseError{position: {line, column}}} = error.reason

    assert is_integer(line) and is_integer(column)
  end

  # sabotage: in Statifier.Compiler.Expressions.compile/3, hardcode the owner
  # passed to Error.expression_compile_error/4 to {:transition, 0} regardless
  # of the caller's `owner` argument -> a {:donedata, _} owner is reported as
  # a transition instead, and this test goes red
  test "compile/3 threads the caller's owner_ref through to the collected error" do
    assert {:error, %Error{reason: {:expression_compile_error, {:donedata, 5}, _source, _err}}} =
             Expressions.compile("1 +", {:donedata, 5}, loc(2))
  end
end
