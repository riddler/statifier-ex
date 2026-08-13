defmodule Statifier.Validator.Checks.IfTest do
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

  describe "check/2 - <else> ordering (spec 4.3.2)" do
    # sabotage: classify_branch/3's cond-carrying-branch-after-nil-cond arm
    # is deleted (only the duplicate-else arm survives) -> the <elseif>
    # after <else> below goes unreported and this {:error, [...]} assertion
    # reddens.
    test "an <elseif> after an <else> is reported at the <elseif>'s own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <log label="one"/>
                      <else/>
                      <log label="two"/>
                      <elseif cond="b"/>
                      <log label="three"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:if_elseif_after_else}} = error]} = validate!(xml)

      assert error.location.start_line == 8
    end

    # sabotage: classify_branch/3's `%Branch{cond: nil}` (duplicate-else)
    # arm is dropped -> the second <else> below goes unreported and this
    # {:error, [...]} assertion reddens.
    test "two <else>s report once, at the second one's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <log label="one"/>
                      <else/>
                      <log label="two"/>
                      <else/>
                      <log label="three"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:if_duplicate_else}} = error]} = validate!(xml)

      assert error.location.start_line == 8
    end

    # sabotage: classify_branch/3's first-nil-cond clause,
    # `%Branch{cond: nil}, false, errors -> {errors, true}`, is changed to
    # `{[Error.if_elseif_after_else(branch.location) | errors], true}` -> the
    # well-formed <else> below (a nil-cond branch that legitimately is last)
    # now reports on sight and this {:ok, _} assertion reddens.
    test "a well-formed <if>/<elseif>/<else> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <log label="one"/>
                      <elseif cond="b"/>
                      <log label="two"/>
                      <else/>
                      <log label="three"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: classify_branch/3's `%Branch{}, false, errors -> {errors,
    # false}` fallback clause is changed to `{errors, true}` (every branch
    # marks seen_nil_cond? regardless of its own cond) -> the second branch
    # below (<elseif cond="b"/>, which has a real cond) is misreported as
    # :if_elseif_after_else and this {:ok, _} assertion reddens.
    test "an <if> with no <else> at all reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <log label="one"/>
                      <elseif cond="b"/>
                      <log label="two"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: transition_ifs/1 is dropped from ifs/1 (only block_ifs and
    # initial_ifs remain) -> the offending <if> inside the <transition>
    # below goes unreported and this {:error, [...]} assertion reddens.
    test "the offending <if> inside a <transition> is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <transition event="go">
                  <if cond="a">
                      <log label="one"/>
                      <else/>
                      <log label="two"/>
                      <elseif cond="b"/>
                      <log label="three"/>
                  </if>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:if_elseif_after_else}}]} = validate!(xml)
    end

    # sabotage: collect_ifs/1's %DIf{} clause drops the `nested` accumulation
    # (only `[if_node]` is returned) -> the offending nested <if> below is
    # never walked and this {:error, [...]} assertion reddens.
    test "the offending <if> nested inside another <if>'s partition is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <if cond="b">
                          <log label="one"/>
                          <else/>
                          <log label="two"/>
                          <elseif cond="c"/>
                          <log label="three"/>
                      </if>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:if_elseif_after_else}}]} = validate!(xml)
    end
  end
end
