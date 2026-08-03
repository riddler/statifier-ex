defmodule SCXMLTest.SystemVariables.Test319 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :if_elements,
         :log_elements,
         :onentry_actions,
         :raise_elements
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test319" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <state id="s0">
            <onentry>
                <if cond="_event !== _statifier_unbound">
                    <raise event="bound" />
                    <else />
                    <raise event="unbound" />
                </if>
            </onentry>
            <transition event="unbound" target="pass" />
            <transition event="bound" target="fail" />
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
      "The SCXML Processor MUST NOT bind _event at initialization time until the first event is processed."

    test_scxml(xml, description, ["pass"], [])
  end
end
