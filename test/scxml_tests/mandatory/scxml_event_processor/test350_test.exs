defmodule SCXMLTest.ScxmlEventProcessor.Test350 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test350" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="'#_scxml_'" />
            <data id="Var2" expr="_sessionid" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="Var1 + Var2" />
                <send delay="5s" event="timeout" />
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" targetexpr="Var1" event="s0Event" />
            </onentry>
            <transition event="s0Event" target="pass" />
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
      "target'. The sending SCXML Processor MUST take the value of this attribute from the 'target' attribute of the send element. The receiving SCXML Processor MUST use this value to determine which session to deliver the message to."

    test_scxml(xml, description, ["pass"], [])
  end
end
