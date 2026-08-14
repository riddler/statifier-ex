defmodule SCXMLTest.Invoke.Test244 do
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
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test244" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/" namelist="Var1">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <datamodel>
                            <data id="Var1" expr="0" />
                        </datamodel>
                        <state id="sub0">
                            <transition cond="Var1==1" target="subFinal">
                                <send target="#_parent" event="success" />
                            </transition>
                            <transition target="subFinal">
                                <send target="#_parent" event="failure" />
                            </transition>
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="success" target="pass" />
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
      "If the invoked process is of type http://www.w3.org/TR/scxml/ and the key of namelist item in the invoke matches the 'id' of a data element in the top-level data declarations of the invoked session, the SCXML Processor MUST use the corresponding value as the initial value of the corresponding data element."

    test_scxml(xml, description, ["pass"], [])
  end
end
