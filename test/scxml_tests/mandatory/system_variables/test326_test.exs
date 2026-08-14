defmodule SCXMLTest.SystemVariables.Test326 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test326" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <datamodel>
            <data id="Var1" expr="_ioprocessors" />
            <data id="Var2" />
        </datamodel>
        <state id="s0">
            <transition cond="Var1 !== undefined" target="s1" />
            <transition cond="true" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <assign location="_ioprocessors" expr="'otherName'" />
                <raise event="foo" />
            </onentry>
            <transition event="error.execution" target="s2" />
            <transition event="*" target="fail" />
        </state>
        <state id="s2">
            <onentry>
                <assign location="Var2" expr="_ioprocessors" />
            </onentry>
            <transition cond="Var1==Var2" target="pass" />
            <transition target="fail" />
        </state>
        <final id="pass">
            <onentry>
                <log label="Outcome" expr="'pass'" />
            </onentry>
        </final>
        <final id="fail">
            <onentry>
                <log label="Outcome" expr="'fail'" />
            </onentry>
        </final>
    </scxml>
    """

    description =
      "The Processor MUST keep the _ioprocessors variable bound to its set of values until the session terminates."

    test_scxml(xml, description, ["pass"], [])
  end
end
