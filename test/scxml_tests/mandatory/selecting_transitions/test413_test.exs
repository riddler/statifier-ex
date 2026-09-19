# Generated from conformance/corpus/w3c.json, case w3c/test413, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 413/test413.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SelectingTransitions.Test413 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :parallel_states
       ]
  @tag conformance: "mandatory", spec: "SelectingTransitions"
  test "test413" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s2p112 s2p122" version="1.0" datamodel="predicator">
        <state id="s1">
            <transition target="fail" />
        </state>
        <state id="s2" initial="s2p1">
            <parallel id="s2p1">
                <transition target="fail" />
                <state id="s2p11" initial="s2p111">
                    <state id="s2p111">
                        <transition target="fail" />
                    </state>
                    <state id="s2p112">
                        <transition cond="In('s2p122')" target="pass" />
                    </state>
                </state>
                <state id="s2p12" initial="s2p121">
                    <state id="s2p121">
                        <transition target="fail" />
                    </state>
                    <state id="s2p122">
                        <transition cond="In('s2p112')" target="pass" />
                    </state>
                </state>
            </parallel>
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
      "At startup, the SCXML Processor MUST place the state machine in the configuration specified by the 'initial' attribute of the scxml element."

    test_scxml(xml, description, ["pass"], [])
  end
end
