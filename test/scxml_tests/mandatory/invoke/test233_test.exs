defmodule SCXMLTest.Invoke.Test233 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :finalize_elements,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test233" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="3s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="subFinal" version="1.0" datamodel="predicator">
                        <final id="subFinal">
                            <onentry>
                                <send target="#_parent" event="childToParent">
                                    <param name="aParam" expr="2" />
                                </send>
                            </onentry>
                        </final>
                    </scxml>
                </content>
                <finalize>
                    <assign location="Var1" expr="_event.data.aParam" />
                </finalize>
            </invoke>
            <transition event="childToParent" cond="Var1==2" target="pass" />
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
      "If there is a finalize handler in the instance of invoke that created the service that generated the event, the SCXML Processor MUST execute the code in that finalize handler right before it removes the event from the event queue for processing."

    test_scxml(xml, description, ["pass"], [])
  end
end
