defmodule SCXMLTest.Send.Test198 do
  use Statifier.Case, async: true

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
  @tag conformance: "mandatory", spec: "send"
  test "test198" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="event1" />
                <send event="timeout" />
            </onentry>
            <transition event="event1" cond="_event.origintype == 'http://www.w3.org/TR/scxml/#SCXMLEventProcessor'" target="pass" />
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
      "If neither the 'type' nor the 'typeexpr' is defined, the SCXML Processor MUST assume the default value of http://www.w3.org/TR/scxml/#SCXMLEventProcessor."

    test_scxml(xml, description, ["pass"], [])
  end
end
