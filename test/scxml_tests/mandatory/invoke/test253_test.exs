defmodule SCXMLTest.Invoke.Test253 do
  use Statifier.Case

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
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test253" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <invoke type="scxml" id="foo">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <datamodel>
                            <data id="Var2" />
                        </datamodel>
                        <state id="sub0">
                            <onentry>
                                <send target="#_parent" event="childRunning" />
                            </onentry>
                            <transition event="parentToChild" target="sub1">
                                <assign location="Var2" expr="_event.origintype" />
                            </transition>
                        </state>
                        <state id="sub1">
                            <transition cond="Var2=='http://www.w3.org/TR/scxml/#SCXMLEventProcessor'" target="subFinal">
                                <send target="#_parent" event="success" />
                            </transition>
                            <transition cond="Var2=='scxml'" target="subFinal">
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
            <state id="s01">
                <transition event="childRunning" target="s02">
                    <assign location="Var1" expr="_event.origintype" />
                </transition>
            </state>
            <state id="s02">
                <transition cond="Var1=='http://www.w3.org/TR/scxml/#SCXMLEventProcessor'" target="s03">
                    <send target="#_foo" event="parentToChild" />
                </transition>
                <transition cond="Var1=='scxml'" target="s03">
                    <send target="#_foo" event="parentToChild" />
                </transition>
                <transition target="fail" />
            </state>
            <state id="s03">
                <transition event="success" target="pass" />
                <transition event="fail" target="fail" />
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
      "When the invoked session is of type http://www.w3.org/TR/scxml/, The SCXML Processor MUST support the use of SCXML Event/IO processor (E.1 SCXML Event I/O Processor) to communicate between the invoking and the invoked sessions."

    test_scxml(xml, description, ["pass"], [])
  end
end
