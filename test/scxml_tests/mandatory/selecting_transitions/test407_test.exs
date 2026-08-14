defmodule SCXMLTest.SelectingTransitions.Test407 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :onexit_actions
       ]
  @tag conformance: "mandatory", spec: "SelectingTransitions"
  test "test407" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onexit>
                <assign location="Var1" expr="Var1 + 1" />
            </onexit>
            <transition target="s1" />
        </state>
        <state id="s1">
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
      "To exit a state, the SCXML Processor MUST execute the executable content in the state's onexit handler."

    test_scxml(xml, description, ["pass"], [])
  end
end
