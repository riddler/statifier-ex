defmodule SCXMLTest.Invoke.Test242 do
  use Statifier.Case, async: true

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
  test "test242" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout1" delay="1s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <invoke type="http://www.w3.org/TR/scxml/" src="file:test242sub1.scxml" />
            <transition event="done.invoke" target="s02" />
            <transition event="timeout1" target="s03" />
        </state>
        <state id="s02">
            <onentry>
                <send event="timeout2" delay="1s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml version="1.0" initial="subFinal1" datamodel="predicator">
                        <final id="subFinal1" />
                    </scxml>
                </content>
            </invoke>
            <transition event="done.invoke" target="pass" />
            <transition event="timeout2" target="fail" />
        </state>
        <state id="s03">
            <onentry>
                <send event="timeout3" delay="1s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml version="1.0" initial="subFinal2" datamodel="predicator">
                        <final id="subFinal2" />
                    </scxml>
                </content>
            </invoke>
            <transition event="timeout3" target="pass" />
            <transition event="done.invoke" target="fail" />
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
      "Invoked services MUST also treat values specified by 'src' and content identically."

    test_scxml(xml, description, ["pass"], [])
  end
end
