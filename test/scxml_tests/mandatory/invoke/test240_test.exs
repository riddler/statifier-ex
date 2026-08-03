defmodule SCXMLTest.Invoke.Test240 do
  use Statifier.Case

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
         :send_param_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test240" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="s01">
                <invoke type="http://www.w3.org/TR/scxml/" namelist="Var1">
                    <content>
                        <scxml initial="sub01" version="1.0" datamodel="predicator">
                            <datamodel>
                                <data id="Var1" expr="0" />
                            </datamodel>
                            <state id="sub01">
                                <transition cond="Var1==1" target="subFinal1">
                                    <send target="#_parent" event="success" />
                                </transition>
                                <transition target="subFinal1">
                                    <send target="#_parent" event="failure" />
                                </transition>
                            </state>
                            <final id="subFinal1" />
                        </scxml>
                    </content>
                </invoke>
                <transition event="success" target="s02" />
                <transition event="failure" target="fail" />
            </state>
            <state id="s02">
                <invoke type="http://www.w3.org/TR/scxml/">
                    <param name="Var1" expr="1" />
                    <content>
                        <scxml initial="sub02" version="1.0" datamodel="predicator">
                            <datamodel>
                                <data id="Var1" expr="0" />
                            </datamodel>
                            <state id="sub02">
                                <transition cond="Var1==1" target="subFinal2">
                                    <send target="#_parent" event="success" />
                                </transition>
                                <transition target="subFinal2">
                                    <send target="#_parent" event="failure" />
                                </transition>
                            </state>
                            <final id="subFinal2" />
                        </scxml>
                    </content>
                </invoke>
                <transition event="success" target="pass" />
                <transition event="failure" target="fail" />
            </state>
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
      "Invoked services of type http://www.w3.org/TR/scxml/, http://www.w3.org/TR/ccxml/, http://www.w3.org/TR/voicexml30/, or http://www.w3.org/TR/voicexml21 MUST interpret values specified by param element or 'namelist' attribute as values that are to be injected into their data models"

    test_scxml(xml, description, ["pass"], [])
  end
end
