defmodule SCXMLTest.Send.Test176 do
  use Statifier.Case, async: true

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
         :send_elements,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test176" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
            <data id="Var2" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="2" />
                <send event="event1">
                    <param name="aParam" expr="Var1" />
                </send>
            </onentry>
            <transition event="event1" target="s1">
                <assign location="Var2" expr="_event.data.aParam" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var2==2" target="pass" />
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
      "The SCXML Processor MUST evaluate param when the parent send element is evaluated and pass the resulting data unmodified to the external service when the message is delivered"

    test_scxml(xml, description, ["pass"], [])
  end
end
