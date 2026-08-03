defmodule SCXMLTest.ScxmlEventProcessor.Test352 do
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
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test352" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send delay="5s" event="timeout" />
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" event="s0Event" />
            </onentry>
            <transition event="s0Event" target="s1">
                <assign location="Var1" expr="_event.origintype" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var1=='http://www.w3.org/TR/scxml/#SCXMLEventProcessor'" target="pass" />
            <transition target="fail" />
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
      "'sourcetype'. The sending SCXML Processor MUST assign this attribute the value \"scxml\". (Note that other types of senders will assign different values.) The receiving Processor MUST use this value as the value of the 'origintype' field of the event that it generates."

    test_scxml(xml, description, ["pass"], [])
  end
end
