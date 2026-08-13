defmodule Statifier.Validator.Checks.AssignTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - assign_expr_and_text" do
    # sabotage: check_assign/1's `if blank?(text) do [] else [...] end`
    # branches are swapped (`if blank?(text) do [...] else [] end`) -> this
    # <assign> (non-blank text, expr present) would report nothing instead
    # of the pair violation, reddening this test's `{:error, [...]}` match.
    test "an <assign> with both expr and children is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <assign location="x" expr="1">literal</assign>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error]} = validate!(xml)

      assert error.location.start_line == 4
      assert error.message =~ "expr"
    end

    # sabotage: same branch swap as the test above - check_assign/1's
    # `if blank?(text) do [] else [...] end` branches are swapped -> this
    # expr-only <assign> (blank text) would now report unconditionally,
    # reddening the {:ok, _} assertion.
    test "an <assign> with only an expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <assign location="x" expr="1"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: check_assign/1 drops its `%DAssign{expr: nil}` head, so the
    # general clause runs even when `expr` is `nil` -> for this text-only
    # <assign>, `Error.assign_expr_and_text(nil, _)` is called, and its own
    # `is_binary(expr)` guard has no other clause to fall back to, crashing
    # with `FunctionClauseError` instead of reaching the clean `{:ok, _}`
    # assertion.
    test "an <assign> with only children reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <assign location="x">literal</assign>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: same branch swap as the first two tests in this describe -
    # check_assign/1's `if blank?(text) do [] else [...] end` branches are
    # swapped -> this whitespace-only-text `<assign>` (blank text) would now
    # report unconditionally, reddening the {:ok, _} assertion.
    test "whitespace-only text alongside an expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <assign location="x" expr="1">
                  </assign>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: assigns/1 covers only `state.onentry` and drops the
    # `transition_assigns/1` call -> the offending <assign> inside the
    # <transition> below goes unreported and the {:error, [...]} assertion
    # reddens.
    test "an offending <assign> inside a <transition> is reported too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <transition event="go">
                  <assign location="x" expr="1">literal</assign>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}}]} = validate!(xml)
    end

    # sabotage: `flatten/1` stops at the document's top-level states instead
    # of walking nested ones -> the nested <state>'s offending <assign>
    # below goes unreported and this assertion reddens.
    test "a nested <state>'s <assign> is walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="outer">
              <state id="inner">
                  <onentry>
                      <assign location="x" expr="1">literal</assign>
                  </onentry>
              </state>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error]} = validate!(xml)

      assert error.location.start_line == 5
    end
  end
end
