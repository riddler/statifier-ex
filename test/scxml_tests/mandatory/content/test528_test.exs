defmodule SCXMLTest.Content.Test528 do
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
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "content"
  test "test528" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0" initial="s01">
            <transition event="error.execution" target="s1" />
            <transition event="done.state.s0" target="fail" />
            <state id="s01">
                <transition target="s02" />
            </state>
            <final id="s02">
                <donedata>
                    <content expr="return" />
                </donedata>
            </final>
        </state>
        <state id="s1">
            <transition event="done.state.s0" cond="_event.data === undefined" target="pass" />
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
      "f the evaluation of 'expr' produces an error, the Processor MUST place error.execution in the internal event queue and use the empty string as the output of the content element."

    test_scxml(xml, description, ["pass"], [])
  end
end
