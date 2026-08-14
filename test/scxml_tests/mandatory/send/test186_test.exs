defmodule SCXMLTest.Send.Test186 do
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
         :send_delay_expressions,
         :send_elements,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test186" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
            <data id="Var2" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="event1" delayexpr="'1s'">
                    <param name="aParam" expr="Var1" />
                </send>
                <assign location="Var1" expr="2" />
            </onentry>
            <transition event="event1" target="s1">
                <assign location="Var2" expr="_event.data.aParam" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var2==1" target="pass" />
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
      "The Processor MUST evaluate all arguments to send when the send element is evaluated, and not when the message is actually dispatched."

    test_scxml(xml, description, ["pass"], [])
  end
end
