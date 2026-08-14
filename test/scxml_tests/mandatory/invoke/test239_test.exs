defmodule SCXMLTest.Invoke.Test239 do
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
  test "test239" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="s01">
                <invoke type="http://www.w3.org/TR/scxml/" src="file:test239sub1.scxml" />
                <transition event="done.invoke" target="s02" />
            </state>
            <state id="s02">
                <invoke type="http://www.w3.org/TR/scxml/">
                    <content>
                        <scxml version="1.0" initial="final" datamodel="predicator">
                            <final id="final" />
                        </scxml>
                    </content>
                </invoke>
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

    description =
      "Invoked services of type http://www.w3.org/TR/scxml/, http://www.w3.org/TR/ccxml/, http://www.w3.org/TR/voicexml30/, or http://www.w3.org/TR/voicexml21 MUST interpret values specified by the content element or 'src' attribute as markup to be executed"

    test_scxml(xml, description, ["pass"], [])
  end
end
