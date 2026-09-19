# Generated from conformance/corpus/scion.json, case
# scion/assign/assign_invalid, by tools/corpus/scion/cases.exs. Regenerate
# with `mise run corpus:emit`; never edit by hand.
#
# The document in this test is test/assign/assign_invalid.scxml from the SCION
# scxml-test-framework (https://github.com/jbeard4/scxml-test-framework),
# licensed under Apache-2.0; the licence text is
# conformance/LICENSES/Apache-2.0.txt.
defmodule SCIONTest.Assign.AssignInvalidTest do
  use Statifier.Case, async: true

  @moduletag :scion
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :wildcard_events
       ]
  @tag spec: "assign"
  test "assign_invalid" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml"
      version="1.0"
      initial="s1">

    <datamodel>
      <data id="o1"/>
    </datamodel>

    <state id="uber">
      <transition event="error.execution" target="pass"/>

      <transition event="*" target="fail">
        <log expr="'unhandled input ' + JSON.stringify(_event)" label="TEST"/>
      </transition>

      <state id="s1">
        <onentry>
          <log expr="'Starting session ' + _sessionid" label="TEST"/>
          <assign location="o1" expr="{p1: 'v1'"/>
        </onentry>
      </state>
    </state>

    <final id="pass">
      <onentry>
        <log expr="'RESULT: pass'" label="TEST"/>
      </onentry>
    </final>

    <final id="fail">
      <onentry>
        <log expr="'RESULT: fail'" label="TEST"/>
      </onentry>
    </final>

    </scxml>
    """

    test_scxml(xml, "", ["pass"], [])
  end
end
