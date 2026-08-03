defmodule SCXMLTest.Param.Test488 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :donedata_elements,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_param_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "param"
  test "test488" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0" initial="s01">
            <transition event="error.execution" target="s1" />
            <transition event="done.state.s0" target="fail" />
            <transition event="done.state.s0" target="fail" />
            <state id="s01">
                <transition target="s02" />
            </state>
            <final id="s02">
                <donedata>
                    <param expr="return" name="someParam" />
                </donedata>
            </final>
        </state>
        <state id="s1">
            <transition event="done.state.s0" cond="_event.data === _statifier_unbound" target="pass" />
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
      "if the evaluation of the 'expr' produces an error, the processor MUST place the error error.execution on the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
