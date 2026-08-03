defmodule SCXMLTest.ScxmlEventProcessor.Test349 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test349" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" event="s0Event" />
            </onentry>
            <transition event="s0Event" target="s2">
                <assign location="Var1" expr="_event.origin" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s2">
            <onentry>
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" targetexpr="Var1" event="s0Event2" />
            </onentry>
            <transition event="s0Event2" target="pass" />
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
      "source'. The sending SCXML Processor MUST populate this attribute with a URI that the receiving processor can use to reply to the sending processor. The receiving SCXML Processor MUST use this URI as the value of the 'origin' field in the event that it generates."

    test_scxml(xml, description, ["pass"], [])
  end
end
