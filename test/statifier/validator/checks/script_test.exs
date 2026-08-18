defmodule Statifier.Validator.Checks.ScriptTest do
  use ExUnit.Case, async: true

  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - script_no_src_or_text" do
    # sabotage: `check_script/1`'s `if blank?(text) do [...] else [] end`
    # branches are swapped -> this empty `<script/>` (blank text) would
    # report nothing instead of the empty-script violation, reddening the
    # `{:error, [...]}` match below.
    test "an empty <script/> is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <script/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
      assert error.message =~ "src"
    end

    # sabotage: same branch swap - `check_script/1`'s
    # `if blank?(text) do [...] else [] end` branches are swapped -> this
    # whitespace-only `<script>` (blank text) would report nothing, and this
    # {:error, [...]} assertion reddens.
    test "whitespace-only text is treated as empty" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <script>
                  </script>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}}], _warnings} = validate!(xml)
    end

    # sabotage: `check_script/1`'s `if blank?(text) do [...] else [] end`
    # branches are swapped -> this non-blank <script> would now report
    # unconditionally, reddening the {:ok, _} assertion.
    test "a <script> with non-blank text reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <script>x = 1;</script>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: `scripts_of/1` covers only `state.onentry` and drops the
    # `transition_scripts/1` call -> the empty <script> inside the
    # <transition> below goes unreported and the {:error, [...]} assertion
    # reddens.
    test "an empty <script> inside a <transition> is reported too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <transition event="go">
                  <script/>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}}], _warnings} = validate!(xml)
    end

    # sabotage: `flatten/1` stops at the document's top-level states instead
    # of walking nested ones -> the nested <state>'s empty <script> below
    # goes unreported and this assertion reddens.
    test "a nested <state>'s empty <script> is walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="outer">
              <state id="inner">
                  <onentry>
                      <script/>
                  </onentry>
              </state>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: `block_scripts/1`'s `|> Enum.flat_map(&descend/1)` step is
    # reverted to a flat `Enum.filter(&match?(%DScript{}, &1))` (no descent
    # into a `%DIf{}`'s branches) -> the empty <script> inside the <if>
    # partition below is invisible to the flat top-level content list and
    # this {:error, [...]} assertion reddens.
    test "an empty <script> inside an <if> partition is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <script/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: `descend/1`'s `%DForeach{content: content}` clause is
    # dropped (only `%DIf{}` and the `other` fallback survive) -> the empty
    # <script> inside the <foreach> body below is invisible to the flat
    # top-level content list and this {:error, [...]} assertion reddens.
    test "an empty <script> inside a <foreach> body is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <foreach array="[1, 2]" item="x">
                      <script/>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: `check/2` drops `document.scripts` from the list it
    # flat-maps `check_script/1` over (walking only `scripts_from_states`) ->
    # an empty top-level <script> is invisible to the state walk entirely
    # and this {:error, [...]} assertion reddens.
    test "an empty top-level <script> (a child of <scxml>) is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <script/>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:script_no_src_or_text}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    # sabotage: same as above - `check/2` drops `document.scripts` from its
    # flat-map -> this non-blank top-level <script> would report nothing
    # either way under that mutation, so this test alone would not redden it
    # (recorded honestly: the negative case here is covered structurally by
    # the positive top-level test above, which does redden under that exact
    # mutation).
    test "a top-level <script> with non-blank text reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <script>x = 1;</script>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end
end
