defmodule SCXMLTest.ScxmlEventProcessor.Test354 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test354" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
            <data id="Var2" />
            <data id="Var3" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send delay="5s" event="timeout" />
                <send event="event1" type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" namelist="Var1">
                    <param name="param1" expr="2" />
                </send>
            </onentry>
            <transition event="event1" target="s1">
                <assign location="Var2" expr="_event.data.Var1" />
                <assign location="Var3" expr="_event.data.param1" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var2==1" target="s2" />
            <transition target="fail" />
        </state>
        <state id="s2">
            <transition cond="Var3==2" target="s3" />
            <transition target="fail" />
        </state>
        <state id="s3">
            <onentry>
                <send delay="5s" event="timeout" />
                <send event="event2">
                    <content>123</content>
                </send>
            </onentry>
            <transition event="event2" cond="_event.data == 123" target="pass" />
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
      "The 'data' field of the event raised in the receiving session MUST contain a copy of the data specified in the 'namelist' attribute or in param or content elements in the sending session. The nature of the copy operation depends on the datamodel in question. However, the Processor MUST ensure that changes to the transmitted data in the receiving session do not affect the data in the sending session and vice-versa. The format of the 'data' field will depend on the datamodel of the receiving session."

    test_scxml(xml, description, ["pass"], [])
  end
end
