# Generated from conformance/corpus/w3c.json, case w3c/test237, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 237/test237.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Invoke.Test237 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test237" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout1" delayexpr="'1s'" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <onentry>
                                <send event="timeout" delayexpr="'2s'" />
                            </onentry>
                            <transition event="timeout" target="subFinal" />
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="timeout1" target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <send event="timeout2" delayexpr="'1.5s'" />
            </onentry>
            <transition event="done.invoke" target="fail" />
            <transition event="*" target="pass" />
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
      "If the invoking session takes a transition out of the state containing the invoke before it receives the 'done.invoke.id' event, the SCXML Processor MUST automatically cancel the invoked component and stop its processing."

    test_scxml(xml, description, ["pass"], [])
  end
end
