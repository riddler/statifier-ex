# Generated from conformance/corpus/w3c.json, case w3c/test350, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 350/test350.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.ScxmlEventProcessor.Test350 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SCXMLEventProcessor"
  test "test350" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="'#_scxml_'" />
            <data id="Var2" expr="_sessionid" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="Var1 + Var2" />
                <send delay="5s" event="timeout" />
                <send type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" targetexpr="Var1" event="s0Event" />
            </onentry>
            <transition event="s0Event" target="pass" />
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
      "target'. The sending SCXML Processor MUST take the value of this attribute from the 'target' attribute of the send element. The receiving SCXML Processor MUST use this value to determine which session to deliver the message to."

    test_scxml(xml, description, ["pass"], [])
  end
end
