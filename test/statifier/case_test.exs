defmodule Statifier.CaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError

  describe "test_scxml/4 feature gate" do
    # sabotage: n/a - asserts the harness's own flunk path, no lib/ behavior
    test "flunks naming every unsupported feature the document uses" do
      xml = """
      <scxml>
        <state id="s1">
          <onentry><script>1</script></onentry>
        </state>
      </scxml>
      """

      error =
        assert_raise AssertionError, fn ->
          Statifier.Case.test_scxml(xml, "scripts on entry", ["s1"], [])
        end

      assert error.message =~ "unsupported SCXML features"
      assert error.message =~ "script_elements"
      assert error.message =~ "scripts on entry"
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

  describe "test_scxml/4 terminal configuration" do
    # sabotage: exit_interpreter/1 populates Effect.Done's configuration from
    # the post-fold machine_state.configuration instead of
    # configuration_at_exit -> the effect comes back with an empty set -> red
    test "asserts against the configuration at exit when the initial configuration terminates" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pass">
          <final id="pass"/>
      </scxml>
      """

      assert :ok = Statifier.Case.test_scxml(xml, "terminates on initialize", ["pass"], [])
    end

    # sabotage: assert_configuration/3's observed_state_chart/2 always returns
    # state_chart unchanged (drops the {:done, _} branch) -> the terminal
    # assertion sees the post-exit empty configuration -> red
    test "asserts against the configuration at exit when an event terminates the chart" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="pass"/>
          </state>
          <final id="pass"/>
      </scxml>
      """

      assert :ok =
               Statifier.Case.test_scxml(xml, "terminates on event", ["s1"], [
                 {%{"name" => "go"}, ["pass"]}
               ])
    end
  end

  describe "test_scxml/4 nameless-leaf assertion" do
    # sabotage: Statifier.active_leaf_states/1 keeps nil ids instead of
    # rejecting them -> raw and translated sizes now match, so
    # assert_every_leaf_named/2 does not raise; the outer AssertionError
    # instead comes from the ordinary equality check (actual now contains
    # nil), so this test's message assertion is what goes red, not the
    # assert_raise itself -> red
    test "raises naming the count when an active leaf has no id" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
          <parallel id="p">
              <state id="s1"/>
              <state/>
          </parallel>
      </scxml>
      """

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Statifier.Case.test_scxml(xml, "nameless region", ["s1"], [])
        end

      assert error.message =~ "active leaf state(s) have no id"
    end
  end
end
