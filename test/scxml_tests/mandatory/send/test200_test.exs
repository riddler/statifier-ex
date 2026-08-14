defmodule SCXMLTest.Send.Test200 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test200" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0">
            <onentry>
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" event="event1" />
                <send event="timeout" />
            </onentry>
            <transition event="event1" target="pass" />
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
      "SCXML Processors MUST support the type http://www.w3.org/TR/scxml/#SCXMLEventProcessor"

    test_scxml(xml, description, ["pass"], [])
  end
end
