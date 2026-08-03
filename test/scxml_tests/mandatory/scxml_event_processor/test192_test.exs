defmodule SCXMLTest.ScxmlEventProcessor.Test192 do
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
  test "test192" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="5s" />
            </onentry>
            <invoke type="scxml" id="invokedChild">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <onentry>
                                <send event="childToParent" target="#_parent" />
                                <send event="timeout" delay="3s" />
                            </onentry>
                            <transition event="parentToChild" target="subFinal">
                                <send target="#_parent" event="eventReceived" />
                            </transition>
                            <transition event="timeout" target="subFinal" />
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="timeout" target="fail" />
            <transition event="done.invoke" target="fail" />
            <state id="s01">
                <transition event="childToParent" target="s02">
                    <send target="#_invokedChild" event="parentToChild" />
                </transition>
            </state>
            <state id="s02">
                <transition event="eventReceived" target="pass" />
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
      "[When using the scxml event i/o processor] If the target is the special term '#_invokeid', where invokeid is the invokeid of an SCXML session that the sending session has created by invoke, the Processor MUST must add the event to the external queue of that session."

    test_scxml(xml, description, ["pass"], [])
  end
end
