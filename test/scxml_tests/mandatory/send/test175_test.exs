# Generated from conformance/corpus/w3c.json, case w3c/test175, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 175/test175.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Send.Test175 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test175" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="'0s'" />
        </datamodel>
        <state id="s0">
            <onentry>
                <assign location="Var1" expr="'1s'" />
                <send delayexpr="Var1" event="event2" />
                <send delayexpr="'.5s'" event="event1" />
            </onentry>
            <transition event="event1" target="s1" />
            <transition event="event2" target="fail" />
        </state>
        <state id="s1">
            <transition event="event2" target="pass" />
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
      "If 'delayexpr' is present, the SCXML Processor MUST evaluate it when the parent send element is evaluated and treat the result as if it had been entered as the value of 'delay'."

    test_scxml(xml, description, ["pass"], [])
  end
end
