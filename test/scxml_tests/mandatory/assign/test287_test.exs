defmodule SCXMLTest.Assign.Test287 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions
       ]
  @tag conformance: "mandatory", spec: "assign"
  test "test287" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0" initial="s0">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="1" />
            </onentry>
            <transition cond="Var1==1" target="pass" />
            <transition target="fail" />
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
      "If the location expression of an assign denotes a valid location in the datamodel and if the value specified by 'expr' is a legal value for the location specified, the processor MUST place the specified value at the specified location."

    test_scxml(xml, description, ["pass"], [])
  end
end
