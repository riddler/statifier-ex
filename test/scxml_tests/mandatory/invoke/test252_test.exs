defmodule SCXMLTest.Invoke.Test252 do
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
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test252" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delayexpr="'1s'" />
            </onentry>
            <transition event="timeout" target="pass" />
            <transition event="childToParent" target="fail" />
            <transition event="done.invoke" target="fail" />
            <state id="s01">
                <onentry>
                    <send event="foo" />
                </onentry>
                <invoke type="http://www.w3.org/TR/scxml/">
                    <content>
                        <scxml initial="sub0" version="1.0" datamodel="predicator">
                            <state id="sub0">
                                <onentry>
                                    <send event="timeout" delayexpr="'.5s'" />
                                </onentry>
                                <transition event="timeout" target="subFinal" />
                                <onexit>
                                    <send target="#_parent" event="childToParent" />
                                </onexit>
                            </state>
                            <final id="subFinal" />
                        </scxml>
                    </content>
                </invoke>
                <transition event="foo" target="s02" />
            </state>
            <state id="s02" />
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
      "Once it cancels an invoked session, the Processor MUST NOT insert any events it receives from the invoked session into the external event queue of the invoking session."

    test_scxml(xml, description, ["pass"], [])
  end
end
