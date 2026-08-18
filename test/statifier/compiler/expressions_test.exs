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

  # sabotage: swap `{:program, compiled, source}` for `{:compiled, compiled,
  # source}` in compile_program/3's success clause -> the tag no longer
  # matches `Machine.program()`'s `:program` arm, and this pattern match
  # fails
  test "compile_program/3 compiles a valid statement program" do
    assert {:ok, {:program, %Predicator.Compiled{} = compiled, "x = 1; y = x + 1;"}} =
             Expressions.compile_program("x = 1; y = x + 1;", {:content, 0}, loc(0))

    refute compiled.instructions == []
  end

  # sabotage: swap compile_program_with_spans/1 back to
  # compile_program_with_positions/1 in compile_program/3 -> every table entry
  # becomes a point {line, column} instead of a {start, stop} span pair, and
  # this test goes red
  test "compile_program/3 stores a span table, not a point-position table" do
    assert {:ok, {:program, %Predicator.Compiled{} = compiled, _source}} =
             Expressions.compile_program("x = 1;\ny = x + 1;", {:content, 0}, loc(0))

    assert map_size(compiled.positions) > 0

    Enum.each(compiled.positions, fn {index, span} ->
      assert {{start_line, start_column}, {end_line, end_column}} = span,
             "instruction #{index} carries #{inspect(span)}, not a span"

      assert is_integer(start_line) and is_integer(start_column)
      assert is_integer(end_line) and is_integer(end_column)
    end)
  end

  # sabotage: in compile_program/3's failure arm, replace parse_error with
  # ParseError.new("x", 1, 1) -> the reported position stops matching
  # predicator's actual failure site, and this test goes red on a source
  # whose failure is not at line 1, column 1.
  test "compile_program/3 reports a failing statement program with a recovered line/column" do
    location = loc(9)

    assert {:error, %Error{} = error} =
             Expressions.compile_program("x = 1;\ny =", {:content, 1}, location)

    assert error.location == location

    assert {:expression_compile_error, {:content, 1}, "x = 1;\ny =",
            %ParseError{position: {line, column}}} = error.reason

    assert {line, column} == {2, 4}
  end

  # sabotage: in compile/3's and compile_program/3's failure arms, rebuild the
  # error with `ParseError.new(parse_error.message, line, column)` (the
  # 3-arity constructor, which always sets `:span` to nil) instead of passing
  # `parse_error` straight through -> `:span` goes back to nil, and this test
  # goes red
  test "compile/3 and compile_program/3 both carry predicator's own non-nil :span, not a hand-built error" do
    assert {:error, %Error{reason: {:expression_compile_error, _owner, _source, expr_error}}} =
             Expressions.compile("score >", {:content, 0}, loc(0))

    assert %ParseError{position: position, span: {start, stop}} = expr_error
    assert {{start_line, start_column}, {end_line, end_column}} = {start, stop}
    assert is_integer(start_line) and is_integer(start_column)
    assert is_integer(end_line) and is_integer(end_column)
    assert position == start

    assert {:error, %Error{reason: {:expression_compile_error, _owner, _source, program_error}}} =
             Expressions.compile_program("x = 1;\ny =", {:content, 1}, loc(9))

    assert %ParseError{position: program_position, span: {program_start, _program_stop}} =
             program_error

    assert program_position == program_start
  end

  # sabotage: swap compile_with_spans/1 for compile_program_with_positions/1
  # in Expressions.compile/3's success clause -> compile/3 starts accepting a
  # statement program too, the sibling-not-arm property this test exists to
  # pin down, and this test goes red
  test "compile/3 rejects a statement program - the sibling-not-arm property" do
    assert {:error, %Error{}} = Expressions.compile("x = 1;", {:content, 2}, loc(4))
  end
end
