defmodule SCXMLTest.SystemVariables.Test336 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test336" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <state id="s0">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" target="s1">
                <send event="bar" targetexpr="_event.origin" typeexpr="_event.origintype" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <send event="baz" />
            </onentry>
            <transition event="bar" target="pass" />
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
      "For external events, the SCXML Processor SHOULD set the origintype field to a value which, in combination with the 'origin' field, will allow the receiver of the event to send a response back to the originating entity."

    test_scxml(xml, description, ["pass"], [])
  end
end
