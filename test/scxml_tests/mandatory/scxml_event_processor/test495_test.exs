defmodule SCXMLTest.ScxmlEventProcessor.Test495 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test495" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="event1" type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" />
                <send event="event2" target="#_internal" type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" />
            </onentry>
            <transition event="event1" target="fail" />
            <transition event="event2" target="s1" />
        </state>
        <state id="s1">
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
      "If no errors occur, the receiving Processor MUST convert the message into an SCXML event, using the mapping defined above and insert it into the appropriate queue, as defined in Send Targets."

    test_scxml(xml, description, ["pass"], [])
  end
end
