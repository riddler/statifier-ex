# Generated from conformance/corpus/w3c.json, case w3c/test518, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 518/test518.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.BasicHttpEventProcessor.Test518 do
  use Statifier.Case, async: true
  alias Mix.Statifier.Corpus.HostCase

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
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
  @tag conformance: "optional", spec: "BasicHTTPEventProcessor"
  test "test518" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="2" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="30s" />
                <send event="test" targetexpr="_ioprocessors['basichttp']['location']" namelist="Var1" type="http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor" />
            </onentry>
            <transition event="test" cond="_event.data['Var1'] == 2" target="pass" />
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
      "If the namelist attribute is defined [in send], the SCXML Processor MUST map its variable names and values to HTTP POST parameters"

    HostCase.with_event_io_processors(
      ["http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"],
      fn send_types -> test_scxml(xml, description, ["pass"], [], send_types: send_types) end
    )
  end
end
