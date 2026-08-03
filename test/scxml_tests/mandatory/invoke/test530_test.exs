defmodule SCXMLTest.Invoke.Test530 do
  use Statifier.Case

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
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test530" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1">
                    <scxml version="1.0">
                        <final />
                    </scxml>
                </assign>
                <send event="timeout" delay="2s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content expr="Var1" />
            </invoke>
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
      "The SCXML Processor MUST evaluate a child content element when the parent invoke element is evaluated and pass the resulting data to the invoked service."

    test_scxml(xml, description, ["pass"], [])
  end
end
