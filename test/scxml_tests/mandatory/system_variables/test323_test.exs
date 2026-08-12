defmodule SCXMLTest.SystemVariables.Test323 do
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
  test "test323" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator" name="machineName">
        <datamodel>
            <data id="Var1" expr="_name" />
        </datamodel>
        <state id="s0">
            <transition cond="Var1 !== undefined" target="pass" />
            <transition cond="true" target="fail" />
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
      "The Processor MUST bind the variable _name at load time to the value of the 'name' attribute of the scxml element. a"

    test_scxml(xml, description, ["pass"], [])
  end
end
