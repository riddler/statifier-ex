defmodule SCXMLTest.Param.Test298 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :data_elements,
         :datamodel,
         :donedata_elements,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "param"
  test "test298" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="1s" />
            </onentry>
            <transition event="error.execution" target="pass" />
            <transition event="*" target="fail" />
            <state id="s01">
                <transition target="s02" />
            </state>
            <final id="s02">
                <donedata>
                    <param name="Var3" location="foo.bar.baz " />
                </donedata>
            </final>
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
      "If the 'location' attribute on a param element does not refer to a valid location in the data model, the processor MUST place the error error.execution on the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
