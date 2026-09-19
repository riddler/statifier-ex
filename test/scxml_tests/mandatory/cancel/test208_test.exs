# Generated from conformance/corpus/w3c.json, case w3c/test208, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 208/test208.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Cancel.Test208 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :cancel_elements,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "cancel"
  test "test208" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send id="foo" event="event1" delayexpr="'1s'" />
                <send event="event2" delayexpr="'1.5s'" />
                <cancel sendid="foo" />
            </onentry>
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
      "The Processor SHOULD make its best attempt to cancel all delayed events with the specified id."

    test_scxml(xml, description, ["pass"], [])
  end
end
