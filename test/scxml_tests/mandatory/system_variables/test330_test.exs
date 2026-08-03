defmodule SCXMLTest.SystemVariables.Test330 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test330" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" datamodel="predicator" name="machineName">
        <state id="s0">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="foo" cond="_event.name !== _statifier_unbound and _event.type !== _statifier_unbound and _event.sendid !== _statifier_unbound and _event.origin !== _statifier_unbound and _event.origintype !== _statifier_unbound and _event.invokeid !== _statifier_unbound and _event.data !== _statifier_unbound" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" cond="_event.name !== _statifier_unbound and _event.type !== _statifier_unbound and _event.sendid !== _statifier_unbound and _event.origin !== _statifier_unbound and _event.origintype !== _statifier_unbound and _event.invokeid !== _statifier_unbound and _event.data !== _statifier_unbound" target="pass" />
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
      "The SCXML Processor MUST insure that the following fields (name, type, sendid, origin, origintype, invokeid, data) are present in all events (_event variable), whether internal or external."

    test_scxml(xml, description, ["pass"], [])
  end
end
