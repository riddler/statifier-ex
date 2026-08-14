defmodule SCXMLTest.Send.Test185 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test185" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="event2" delayexpr="'1s'" />
                <send event="event1" />
            </onentry>
            <transition event="event1" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition event="event2" target="pass" />
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
      "If a delay is specified via 'delay' or 'delayexpr', the SCXML Processor MUST interpret the character string as a time interval. the SCXML Processor MUST dispatch the message only when the delay interval elapses."

    test_scxml(xml, description, ["pass"], [])
  end
end
