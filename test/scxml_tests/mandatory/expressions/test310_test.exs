defmodule SCXMLTest.Expressions.Test310 do
  use Statifier.Case

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
         :parallel_states
       ]
  @tag conformance: "mandatory", spec: "Expressions"
  test "test310" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="p">
        <parallel id="p">
            <state id="s0">
                <transition cond="In('s1')" target="pass" />
                <transition target="fail" />
            </state>
            <state id="s1" />
        </parallel>
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
      "All datamodels MUST support the 'In()' predicate, which takes a stateID as its argument and returns true if the state machine is in that state."

    test_scxml(xml, description, ["pass"], [])
  end
end
