defmodule SCXMLTest.SystemVariables.Test324 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test324" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator" name="machineName">
        <state id="s0">
            <transition cond="_name == 'machineName'" target="s1" />
            <transition target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <assign location="_name" expr="'otherName'" />
            </onentry>
            <transition cond="_name == 'machineName'" target="pass" />
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
      "The Processor MUST keep the _name variable bound to the value of the 'name' attribute of the scxml element until the session terminates."

    test_scxml(xml, description, ["pass"], [])
  end
end
