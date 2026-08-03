defmodule SCXMLTest.Invoke.Test236 do
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
         :onexit_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test236" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout" delayexpr="'2s'" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="subFinal" version="1.0" datamodel="predicator">
                        <final id="subFinal">
                            <onexit>
                                <send target="#_parent" event="childToParent" />
                            </onexit>
                        </final>
                    </scxml>
                </content>
            </invoke>
            <transition event="childToParent" target="s1" />
            <transition event="done.invoke" target="fail" />
        </state>
        <state id="s1">
            <transition event="done.invoke" target="s2" />
            <transition event="*" target="fail" />
        </state>
        <state id="s2">
            <transition event="timeout" target="pass" />
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
      "The external service MUST NOT generate any other events after the invoke.done.invokeid event."

    test_scxml(xml, description, ["pass"], [])
  end
end
