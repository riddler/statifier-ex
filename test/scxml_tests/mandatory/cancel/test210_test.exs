defmodule SCXMLTest.Cancel.Test210 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :cancel_elements,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "cancel"
  test "test210" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="'bar'" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send id="foo" event="event1" delayexpr="'1s'" />
                <send event="event2" delayexpr="'1.5s'" />
                <assign location="Var1" expr="'foo'" />
                <cancel sendidexpr="Var1" />
            </onentry>
            <transition event="event2" target="pass" />
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
      "If the 'sendidexpr' attribute is present, the SCXML Processor MUST evaluate it when the parent cancel element is evaluated and treat the result as if it had been entered as the value of 'sendid'."

    test_scxml(xml, description, ["pass"], [])
  end
end
