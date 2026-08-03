defmodule SCXMLTest.SCXMLEventProcessor.Test190 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test190" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="'#_scxml_'" />
            <data id="Var2" expr="_sessionid" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="Var1 + Var2" />
                <send event="event2" targetexpr="Var1" />
                <raise event="event1" />
                <send event="timeout" />
            </onentry>
            <transition event="event1" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
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
      "[When using the scxml event i/o processor] If the target is the special term '#_scxml_sessionid', where sessionid is the id of an SCXML session that is accessible to the Processor, the Processor MUST add the event to the external queue of that session."

    test_scxml(xml, description, ["pass"], [])
  end
end
