defmodule SCXMLTest.Send.Test553 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test553" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0">
            <onentry>
                <send event="timeout" delayexpr="'1s'" />
                <send event="event1" namelist="&quot;foo" />
            </onentry>
            <transition event="timeout" target="pass" />
            <transition event="event1" target="fail" />
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
      "If the evaluation of send's arguments produces an error, If the evaluation of send's arguments produces an error, the Processor MUST discard the message without attempting to deliver it."

    test_scxml(xml, description, ["pass"], [])
  end
end
