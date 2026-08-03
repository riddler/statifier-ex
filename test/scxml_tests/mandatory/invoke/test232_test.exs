defmodule SCXMLTest.Invoke.Test232 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test232" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="3s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="subFinal" version="1.0" datamodel="predicator">
                        <final id="subFinal">
                            <onentry>
                                <send target="#_parent" event="childToParent1" />
                                <send target="#_parent" event="childToParent2" />
                            </onentry>
                        </final>
                    </scxml>
                </content>
            </invoke>
            <transition event="timeout" target="fail" />
            <state id="s01">
                <transition event="childToParent1" target="s02" />
            </state>
            <state id="s02">
                <transition event="childToParent2" target="s03" />
            </state>
            <state id="s03">
                <transition event="done.invoke" target="pass" />
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

    description = "he invoked external service MAY return multiple events while it is processing"

    test_scxml(xml, description, ["pass"], [])
  end
end
