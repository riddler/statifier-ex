# Generated from conformance/corpus/w3c.json, case w3c/test531, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 531/test531.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.BasicHttpEventProcessor.Test531 do
  use Statifier.Case, async: true
  alias Mix.Statifier.Corpus.HostCase

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_delay_expressions,
         :send_elements,
         :send_param_elements,
         :target_expressions,
         :wildcard_events
       ]
  @tag conformance: "optional", spec: "BasicHTTPEventProcessor"
  test "test531" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <state id="s0">
            <onentry>
                <send event="timeout" delay="3s" />
                <send targetexpr="_ioprocessors['basichttp']['location']" type="http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor">
                    <param name="_scxmleventname" expr="'test'" />
                </send>
            </onentry>
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
      "If a single instance of the parameter '_scxmleventname' is present, the SCXML Processor MUST use its value as the name of the SCXML event that it raises."

    HostCase.with_event_io_processors(
      ["http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"],
      fn send_types -> test_scxml(xml, description, ["pass"], [], send_types: send_types) end
    )
  end
end
