defmodule Statifier.CaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError

  describe "test_scxml/4 feature gate" do
    # sabotage: n/a - asserts the harness's own flunk path, no lib/ behavior
    test "flunks naming every unsupported feature the document uses" do
      xml = """
      <scxml>
        <state id="s1">
          <onentry><assign location="x" expr="1"/></onentry>
        </state>
      </scxml>
      """

      error =
        assert_raise AssertionError, fn ->
          Statifier.Case.test_scxml(xml, "assigns on entry", ["s1"], [])
        end

      assert error.message =~ "unsupported SCXML features"
      assert error.message =~ "assign_elements"
      assert error.message =~ "assigns on entry"
    end

    # sabotage: n/a - asserts the harness fails rather than skips, no lib/ behavior
    test "never skips - an unsupported document fails the test" do
      xml = """
      <scxml><state id="s1"><transition cond="ready" target="s1"/></state></scxml>
      """

      assert_raise AssertionError, fn ->
        Statifier.Case.test_scxml(xml, "", ["s1"], [])
      end
    end
  end

  describe "test_scxml/4 end to end" do
    # sabotage: select_transitions/2 discards its enabled set -> red
    test "drives a compound document through compile, initialize, and one event" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="s2"/>
          </state>
          <state id="s2"/>
      </scxml>
      """

      assert :ok =
               Statifier.Case.test_scxml(xml, "moves on event", ["s1"], [
                 {%{"name" => "go"}, ["s2"]}
               ])
    end
  end
end
