defmodule SCXMLTest.Send.Test173 do
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
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test173" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="27" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="'#_internal'" />
                <send targetexpr="Var1" event="event1" />
            </onentry>
            <transition event="event1" target="pass" />
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
      "If 'targetexpr' is present, the SCXML Processor MUST evaluate it when the parent send element is evaluated and treat the result as if it had been entered as the value of 'target'."

    test_scxml(xml, description, ["pass"], [])
  end
end
