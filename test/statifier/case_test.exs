defmodule Statifier.CaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError

  describe "test_scxml/4 feature gate" do
    # sabotage: n/a - asserts the harness's own flunk path, no lib/ behavior
    test "flunks naming every unsupported feature the document uses" do
      xml = """
      <scxml>
        <state id="s1">
          <onentry><log expr="hi"/></onentry>
        </state>
      </scxml>
      """

      error =
        assert_raise AssertionError, fn ->
          Statifier.Case.test_scxml(xml, "logs on entry", ["s1"], [])
        end

      assert error.message =~ "unsupported SCXML features"
      assert error.message =~ "basic_states"
      assert error.message =~ "log_elements"
      assert error.message =~ "onentry_actions"
      assert error.message =~ "logs on entry"
    end

    # sabotage: n/a - asserts the harness fails rather than skips, no lib/ behavior
    test "never skips - an unsupported document fails the test" do
      xml = """
      <scxml><state id="s1"/></scxml>
      """

      assert_raise AssertionError, fn ->
        Statifier.Case.test_scxml(xml, "", ["s1"], [])
      end
    end
  end

  describe "test_scxml/4 library seam" do
    # sabotage: n/a - asserts the not-yet-implemented seam message, no lib/ behavior
    test "flunks naming the missing parse call once the feature gate passes" do
      xml = """
      <scxml/>
      """

      error =
        assert_raise AssertionError, fn ->
          Statifier.Case.test_scxml(xml, "", [], [])
        end

      assert error.message =~ "Statifier.parse/1 does not exist yet"
      assert error.message =~ "test/support/case.ex"
    end
  end
end
