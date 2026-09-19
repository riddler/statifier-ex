# Generated from conformance/corpus/w3c.json, case w3c/test576, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 576/test576.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Scxml.Test576 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :parallel_states,
         :raise_elements,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "scxml"
  test "test576" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s11p112 s11p122" datamodel="predicator" version="1.0">
        <state id="s0">
            <transition target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <send event="timeout" delay="1s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="s11" initial="s111">
                <state id="s111" />
                <parallel id="s11p1">
                    <state id="s11p11" initial="s11p111">
                        <state id="s11p111" />
                        <state id="s11p112">
                            <onentry>
                                <raise event="In-s11p112" />
                            </onentry>
                        </state>
                    </state>
                    <state id="s11p12" initial="s11p121">
                        <state id="s11p121" />
                        <state id="s11p122">
                            <transition event="In-s11p112" target="pass" />
                        </state>
                    </state>
                </parallel>
            </state>
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
      "At system initialization time, the SCXML Processor MUST enter the states specified by the 'initial' attribute, if it is present."

    test_scxml(xml, description, ["pass"], [])
  end
end
