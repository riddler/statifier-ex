defmodule SCXMLTest.SystemVariables.Test325 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test325" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <datamodel>
            <data id="Var1" expr="_ioprocessors" />
        </datamodel>
        <state id="s0">
            <transition cond="Var1 !== undefined" target="pass" />
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
      "The Processor MUST bind the variable _ioprocessors to a set of values, one for each Event I/O Processor that it supports."

    test_scxml(xml, description, ["pass"], [])
  end
end
