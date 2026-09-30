# Generated from conformance/corpus/w3c.json, case w3c/test510, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 510/test510.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.BasicHttpEventProcessor.Test510 do
  use Statifier.Case, async: true
  alias Mix.Statifier.Corpus.HostCase

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_delay_expressions,
         :send_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "optional", spec: "BasicHTTPEventProcessor"
  test "test510" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0">
            <onentry>
                <send event="timeout" delay="30s" />
                <send event="test" targetexpr="_ioprocessors['basichttp']['location']" type="http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor" />
                <raise event="internal" />
            </onentry>
            <transition event="internal" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition event="test" target="pass" />
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
      "The SCXML Processor MUST validate the message it receives [via the Basic HTTP Event I/O Processor] and then MUST build the appropriate SCXML event and MUST add it to the external event queue"

    HostCase.with_event_io_processors(
      ["http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"],
      fn send_types -> test_scxml(xml, description, ["pass"], [], send_types: send_types) end
    )
  end
end
