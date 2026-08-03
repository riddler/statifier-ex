defmodule :"Elixir.SCXMLTest.Ecma-profile.Test278" do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions
       ]
  @tag conformance: "optional", spec: "ecma-profile"
  test "test278" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <transition cond="Var1==1" target="pass" />
            <transition target="fail" />
        </state>
        <state id="s1">
            <datamodel>
                <data id="Var1" expr="1" />
            </datamodel>
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
      "In the ECMAScript data model, the SCXML processor MUST allow any data element to be accessed from any state."

    test_scxml(xml, description, ["pass"], [])
  end
end
