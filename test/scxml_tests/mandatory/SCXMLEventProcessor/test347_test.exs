defmodule SCXMLTest.SCXMLEventProcessor.Test347 do
  use Statifier.Case

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
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test347" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0" initial="s01">
            <invoke id="child" type="scxml">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator" name="machineName">
                        <state id="sub0">
                            <onentry>
                                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" target="#_parent" event="childToParent" />
                            </onentry>
                            <transition event="parentToChild" target="subFinal" />
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <onentry>
                <send delay="20s" event="timeout" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="s01">
                <transition event="childToParent" target="s02" />
            </state>
            <state id="s02">
                <onentry>
                    <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" target="#_child" event="parentToChild" />
                </onentry>
                <transition event="done.invoke" target="pass" />
                <transition event="error" target="fail" />
            </state>
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
      "SCXML Processors MUST support sending messages to and receiving messages from other SCXML sessions using the SCXML Event I/O Processor."

    test_scxml(xml, description, ["pass"], [])
  end
end
