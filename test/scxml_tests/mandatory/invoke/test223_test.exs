defmodule SCXMLTest.Invoke.Test223 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :send_idlocation,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test223" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="1s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/" idlocation="Var1">
                <content>
                    <scxml initial="subFinal" version="1.0" datamodel="predicator">
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="*" target="s1" />
        </state>
        <state id="s1">
            <transition cond="Var1 !== undefined" target="pass" />
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
      "If the 'idlocation' attribute is present, the SCXML Processor MUST generate an id automatically when the invoke element is evaluated and store it in the location specified by 'idlocation'."

    test_scxml(xml, description, ["pass"], [])
  end
end
