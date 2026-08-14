defmodule SCXMLTest.Invoke.Test234 do
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
         :finalize_elements,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :parallel_states,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :send_param_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test234" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="p0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
            <data id="Var2" expr="1" />
        </datamodel>
        <parallel id="p0">
            <onentry>
                <send event="timeout" delay="3s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="p01">
                <invoke type="http://www.w3.org/TR/scxml/">
                    <content>
                        <scxml version="1.0" initial="subFinal1" datamodel="predicator">
                            <final id="subFinal1">
                                <onentry>
                                    <send target="#_parent" event="childToParent">
                                        <param name="aParam" expr="2" />
                                    </send>
                                </onentry>
                            </final>
                        </scxml>
                    </content>
                    <finalize>
                        <assign location="Var1" expr="_event.data.aParam" />
                    </finalize>
                </invoke>
                <transition event="childToParent" cond="Var1==2" target="s1" />
                <transition event="childToParent" target="fail" />
            </state>
            <state id="p02">
                <invoke type="http://www.w3.org/TR/scxml/">
                    <content>
                        <scxml version="1.0" initial="sub0" datamodel="predicator">
                            <state id="sub0">
                                <onentry>
                                    <send event="timeout" delay="2s" />
                                </onentry>
                                <transition event="timeout" target="subFinal2" />
                            </state>
                            <final id="subFinal2" />
                        </scxml>
                    </content>
                    <finalize>
                        <assign location="Var2" expr="_event.data.aParam" />
                    </finalize>
                </invoke>
            </state>
        </parallel>
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
      "t MUST NOT execute the finalize handler in any other instance of invoke besides the one in the instance of invoke that created the service that generated the event."

    test_scxml(xml, description, ["pass"], [])
  end
end
