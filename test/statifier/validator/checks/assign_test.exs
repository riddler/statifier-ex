defmodule Statifier.Validator.Checks.AssignTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
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

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error], _warnings} =
               validate!(xml)

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

      assert {:ok, _document, _warnings} = validate!(xml)
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

      assert {:ok, _document, _warnings} = validate!(xml)
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

      assert {:ok, _document, _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}}], _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: block_assigns/1's `|> Enum.flat_map(&descend/1)` step is
    # reverted to the old flat `Enum.filter(&match?(%DAssign{}, &1))` (no
    # descent into a %DIf{}'s branches) -> the offending <assign> inside the
    # <if> partition below is invisible to the flat top-level content list
    # and this {:error, [...]} assertion reddens.
    test "an <assign> with both expr and children inside an <if> partition is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <assign location="x" expr="1">literal</assign>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: descend/1's `%DForeach{content: content}` clause is dropped
    # (only `%DIf{}` and the `other` fallback survive) -> the offending
    # <assign> inside the <foreach> body below is invisible to the flat
    # top-level content list and this {:error, [...]} assertion reddens.
    test "an <assign> with both expr and children inside a <foreach> body is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <foreach array="[1, 2]" item="x">
                      <assign location="y" expr="1">literal</assign>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: same as above - descend/1's `%DForeach{content: content}`
    # clause is dropped -> the offending <assign> inside the <foreach>
    # nested inside the <if> partition below is invisible and this
    # {:error, [...]} assertion reddens.
    test "an <assign> inside a <foreach> nested in an <if> partition is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <foreach array="[1, 2]" item="x">
                          <assign location="y" expr="1">literal</assign>
                      </foreach>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:assign_expr_and_text, "1"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end
  end
end
