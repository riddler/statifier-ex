defmodule SCXMLTest.Expressions.Test312 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements
       ]
  @tag conformance: "mandatory", spec: "Expressions"
  test "test312" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="return" />
                <raise event="foo" />
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
      "If a value expression does not return a legal data value, the SCXML processor MUST place the error error.execution in the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
