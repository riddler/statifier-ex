defmodule SCXMLTest.OnExit.Test377 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :onexit_actions,
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "onexit"
  test "test377" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0">
        <state id="s0">
            <onexit>
                <raise event="event1" />
            </onexit>
            <onexit>
                <raise event="event2" />
            </onexit>
            <transition target="s1" />
        </state>
        <state id="s1">
            <transition event="event1" target="s2" />
            <transition event="*" target="fail" />
        </state>
        <state id="s2">
            <transition event="event2" target="pass" />
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
      "The SCXML processor MUST execute the onexit handlers of a state in document order when the state is exited."

    test_scxml(xml, description, ["pass"], [])
  end
end
