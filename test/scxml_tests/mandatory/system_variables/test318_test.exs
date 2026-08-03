defmodule SCXMLTest.SystemVariables.Test318 do
  use Statifier.Case

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
         :raise_elements
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test318" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator" name="machineName">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="foo" target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <raise event="bar" />
                <assign location="Var1" expr="_event.name" />
            </onentry>
            <transition cond="Var1=='foo'" target="pass" />
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
      "The SCXML Processor MUST bind the _event variable when an event is pulled off the internal or external event queue to be processed, and MUST keep the variable bound to that event until another event is processed."

    test_scxml(xml, description, ["pass"], [])
  end
end
