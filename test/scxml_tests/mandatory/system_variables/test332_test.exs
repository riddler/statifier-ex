# Generated from conformance/corpus/w3c.json, case w3c/test332, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 332/test332.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SystemVariables.Test332 do
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
         :send_elements,
         :send_idlocation,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test332" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" datamodel="predicator" name="machineName">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send target="baz" event="foo" idlocation="Var1" />
            </onentry>
            <transition event="error" target="s1">
                <assign location="Var2" expr="_event.sendid" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var1===Var2" target="pass" />
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
      "If the sending entity has specified a value for this, the Processor MUST set this field to that value. Otherwise, in the case of error events triggered by a failed attempt to send an event, the Processor MUST set the sendid field to the send id of the triggering send element."

    test_scxml(xml, description, ["pass"], [])
  end
end
