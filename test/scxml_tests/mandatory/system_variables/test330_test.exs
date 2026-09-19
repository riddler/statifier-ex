# Generated from conformance/corpus/w3c.json, case w3c/test330, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 330/test330.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SystemVariables.Test330 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test330" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" datamodel="predicator" name="machineName">
        <state id="s0">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="foo" cond="_event.name !== undefined and _event.type !== undefined and _event.sendid !== undefined and _event.origin !== undefined and _event.origintype !== undefined and _event.invokeid !== undefined and _event.data !== undefined" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" cond="_event.name !== undefined and _event.type !== undefined and _event.sendid !== undefined and _event.origin !== undefined and _event.origintype !== undefined and _event.invokeid !== undefined and _event.data !== undefined" target="pass" />
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
      "The SCXML Processor MUST insure that the following fields (name, type, sendid, origin, origintype, invokeid, data) are present in all events (_event variable), whether internal or external."

    test_scxml(xml, description, ["pass"], [])
  end
end
