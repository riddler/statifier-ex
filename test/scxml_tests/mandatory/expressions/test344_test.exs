defmodule SCXMLTest.Expressions.Test344 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "Expressions"
  test "test344" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0">
            <transition cond="1" target="fail" />
            <transition target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="error.execution" target="pass" />
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
      "If a conditional expression cannot be evaluated as a boolean value ('true' or 'false') or if its evaluation causes an error, the SCXML processor MUST place the error 'error.execution' in the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
