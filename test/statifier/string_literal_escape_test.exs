defmodule Statifier.StringLiteralEscapeTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler.Error, as: CompilerError

  # What a chart sees for a `\u` or `\U` escape inside a string literal, as
  # docs/upgrading.md's 2.12.0 section states it (the bullet that opens
  # "With the same move, a string literal holding a `\u` or `\U` escape").
  # The answers come from the locked predicator, 9.4.2, whose lexer refuses
  # both escapes: an expression the compiler checks at load refuses the
  # document, a deferred one raises `error.execution` when it runs and is
  # reported under `Statifier.Publish.findings/2`'s row S13, and text read
  # as a value keeps its text, quotes and backslash included.
  #
  # Each literal below is the source text `'Montr\u00e9al'` (or its `\U`
  # spelling): the Elixir strings escape the backslash so the document
  # carries it.

  @literal "'Montr\\u00e9al'"
  @upper_literal "'Montr\\U00e9al'"

  defp chart(state_body, datamodel \\ "") do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="shelved">
        <datamodel>#{datamodel}</datamodel>
        <state id="shelved">
            #{state_body}
            <transition event="error.execution" target="refused"/>
        </state>
        <state id="refused"/>
        <final id="lent"/>
    </scxml>
    """
  end

  describe "an expression the compiler checks at load" do
    # sabotage: build_cond/2 answering {:ok, nil} for a cond that fails to
    # compile -> the document compiles -> red
    test "refuses the document with an expression_compile_error" do
      source =
        chart(~s|<transition event="loan.requested" cond="branch == #{@literal}" target="lent"/>|)

      assert {:error, [%CompilerError{reason: reason}]} = Statifier.compile(source)

      assert {:expression_compile_error, {:transition, 0}, "branch == " <> @literal,
              %Predicator.Errors.ParseError{}} = reason
    end
  end

  describe "an expression the compiler defers" do
    # sabotage: Datamodel's bind_value/4 binding an {:invalid, _} value
    # without raising -> the chart stays in shelved -> red
    test "raises error.execution when the <data expr> runs" do
      assert {:ok, machine} =
               Statifier.compile(chart("", ~s|<data id="branch" expr="#{@literal}"/>|))

      {machine_state, _effects} = Statifier.initialize(machine)

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["refused"])

      assert %{
               "name" => "error.execution",
               "data" => %CompilerError{
                 reason: {:expression_compile_error, {:data, 0}, @literal, _parse_error}
               }
             } = machine_state.datamodel["_event"]
    end

    # sabotage: Publish's check("S13", ...) walking the machine with its
    # contents and data elements emptied -> no finding -> red
    test "is reported under row S13 for an <assign expr>" do
      source =
        chart(
          ~s|<onentry><assign location="branch" expr="#{@upper_literal}"/></onentry>|,
          ~s|<data id="branch"/>|
        )

      assert {:ok, machine} = Statifier.compile(source)

      assert [
               %{
                 row: "S13",
                 kind: :compile_error,
                 data: %{element: :assign, source: @upper_literal}
               }
             ] = Statifier.Publish.findings(machine)
    end
  end

  describe "text read as a value" do
    # sabotage: Expressions.inline_value/1's fallback dropping the
    # backslash from the text -> red
    test "keeps a <data> and an <assign> element's text, quotes and backslash included" do
      source =
        chart(
          ~s|<onentry><assign location="hold_branch">#{@upper_literal}</assign></onentry>|,
          ~s|<data id="branch">#{@literal}</data><data id="hold_branch"/>|
        )

      assert {:ok, machine} = Statifier.compile(source)
      {machine_state, _effects} = Statifier.initialize(machine)

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["shelved"])
      assert machine_state.datamodel["branch"] == @literal
      assert machine_state.datamodel["hold_branch"] == @upper_literal
    end
  end
end
