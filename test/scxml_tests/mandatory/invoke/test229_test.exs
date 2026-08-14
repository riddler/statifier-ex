defmodule SCXMLTest.Invoke.Test229 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :targetless_transitions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test229" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout" delay="3s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/" autoforward="true">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <onentry>
                                <send target="#_parent" event="childToParent" />
                                <send event="timeout" delay="3s" />
                            </onentry>
                            <transition event="childToParent" target="subFinal">
                                <send target="#_parent" event="eventReceived" />
                            </transition>
                            <transition event="*" target="subFinal" />
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="childToParent" />
            <transition event="eventReceived" target="pass" />
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
      "When the 'autoforward' attribute is set to true, the SCXML Processor MUST send an exact copy of every external event it receives to the invoked process."

    test_scxml(xml, description, ["pass"], [])
  end
end
