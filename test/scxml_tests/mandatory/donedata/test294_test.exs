defmodule SCXMLTest.Donedata.Test294 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :donedata_elements,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_param_elements
       ]
  @tag conformance: "mandatory", spec: "donedata"
  test "test294" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0" initial="s01">
            <transition event="done.state.s0" cond="_event.data['Var1']==1" target="s1" />
            <transition event="done.state.s0" target="fail" />
            <state id="s01">
                <transition target="s02" />
            </state>
            <final id="s02">
                <donedata>
                    <param name="Var1" expr="1" />
                </donedata>
            </final>
        </state>
        <state id="s1" initial="s11">
            <transition event="done.state.s1" cond="_event.data == 'foo'" target="pass" />
            <transition event="done.state.s1" target="fail" />
            <state id="s11">
                <transition target="s12" />
            </state>
            <final id="s12">
                <donedata>
                    <content>foo</content>
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
      "In cases where the SCXML Processor generates a 'done' event upon entry into the final state, it MUST evaluate the donedata elements param or content children and place the resulting data in the _event.data field. The exact format of that data will be determined by the datamodel"

    test_scxml(xml, description, ["pass"], [])
  end
end
