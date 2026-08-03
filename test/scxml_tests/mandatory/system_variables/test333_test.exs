defmodule SCXMLTest.SystemVariables.Test333 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test333" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" datamodel="predicator" name="machineName">
        <state id="s0">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" cond="_event.sendid === _statifier_unbound" target="pass" />
            <transition event="*" target="fail" />
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
      "For events other than error events triggered by a failed attempt to send an event, if the sending entity did not specify a value for the sendid field, the Processor MUST leave the sendid field (of _event) blank."

    test_scxml(xml, description, ["pass"], [])
  end
end
