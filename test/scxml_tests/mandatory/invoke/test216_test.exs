defmodule SCXMLTest.Invoke.Test216 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test216" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="'foo'" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="5s" />
                <assign location="Var1" expr="'file:test216sub1.scxml'" />
            </onentry>
            <invoke srcexpr="Var1" type="http://www.w3.org/TR/scxml" />
            <transition event="done.invoke" target="pass" />
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
      "If the srcexpr attribute is present, the SCXML Processor MUST evaluate it when the parent invoke element is evaluated and treat the result as if it had been entered as the value of 'src'."

    test_scxml(xml, description, ["pass"], [])
  end
end
