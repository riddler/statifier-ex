defmodule SCXMLTest.Invoke.Test245 do
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
  test "test245" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var2" expr="3" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/" namelist="Var2">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <transition cond="Var2 !== undefined" target="subFinal">
                                <send target="#_parent" event="failure" />
                            </transition>
                            <transition target="subFinal">
                                <send target="#_parent" event="success" />
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
      "If the invoked process is of type http://www.w3.org/TR/scxml/, and the name of a param element or the key of of a namelis item do not match the name of a data element in the invoked process, the Processor MUST NOT add the value of the param element or namelist key/value pair to the invoked session's data model."

    test_scxml(xml, description, ["pass"], [])
  end
end
