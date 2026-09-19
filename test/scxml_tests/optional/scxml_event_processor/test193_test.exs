# Generated from conformance/corpus/w3c.json, case w3c/test193, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 193/test193.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.ScxmlEventProcessor.Test193 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "optional", spec: "SCXMLEventProcessor"
  test "test193" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="internal" />
                <send event="event1" type="http://www.w3.org/TR/scxml/#SCXMLEventProcessor" />
                <send event="timeout" delay="1s" />
            </onentry>
            <transition event="event1" target="fail" />
            <transition event="internal" target="s1" />
        </state>
        <state id="s1">
            <transition event="event1" target="pass" />
            <transition event="timeout" target="fail" />
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
      "[When using the scxml event i/o processor] If neither the 'target' nor the 'targetexpr' attribute is specified, the SCXML Processor MUST add the event to the external event queue of the sending session."

    test_scxml(xml, description, ["pass"], [])
  end
end
