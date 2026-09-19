# Generated from conformance/corpus/w3c.json, case w3c/test336, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 336/test336.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SystemVariables.Test336 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test336" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <state id="s0">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" target="s1">
                <send event="bar" targetexpr="_event.origin" typeexpr="_event.origintype" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <send event="baz" />
            </onentry>
            <transition event="bar" target="pass" />
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
      "For external events, the SCXML Processor SHOULD set the origintype field to a value which, in combination with the 'origin' field, will allow the receiver of the event to send a response back to the originating entity."

    test_scxml(xml, description, ["pass"], [])
  end
end
