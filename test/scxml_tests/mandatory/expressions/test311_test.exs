defmodule SCXMLTest.Expressions.Test311 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "Expressions"
  test "test311" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0">
            <onentry>
                <send event="timeout" delay="1s" />
                <assign location="foo.bar.baz " expr="1" />
            </onentry>
            <transition event="error.execution" target="pass" />
            <transition event=".*" target="fail" />
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
      "If a location expression cannot be evaluated to yield a valid location, the SCXML processor MUST place the error error.execution in the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
