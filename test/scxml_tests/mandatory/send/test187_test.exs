defmodule SCXMLTest.Send.Test187 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test187" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout" delayexpr="'1s'" />
            </onentry>
            <invoke type="scxml">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <onentry>
                                <send event="childToParent" target="#_parent" delayexpr="'.5s'" />
                            </onentry>
                            <transition target="subFinal" />
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="childToParent" target="fail" />
            <transition event="timeout" target="pass" />
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
      "If the SCXML session terminates before the delay interval has elapsed, the SCXML Processor MUST discard the message without attempting to deliver it."

    test_scxml(xml, description, ["pass"], [])
  end
end
