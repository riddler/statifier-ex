defmodule SCXMLTest.Invoke.Test226sub1 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test226sub1" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <transition cond="Var1 !== _statifier_unbound" target="final">
                <send target="#_parent" event="varBound" />
            </transition>
            <transition target="final" />
        </state>
        <final id="final" />
    </scxml>
    """

    description =
      "When the invoke element is executed, the SCXML Processor MUST start a new logical instance of the external service specified in 'type' or 'typexpr', passing it the URL specified by 'src' or the data specified by content, or param."

    test_scxml(xml, description, ["pass"], [])
  end
end
