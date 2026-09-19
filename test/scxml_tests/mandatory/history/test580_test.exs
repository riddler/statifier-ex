# Generated from conformance/corpus/w3c.json, case w3c/test580, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 580/test580.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.History.Test580 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :history_states,
         :initial_elements,
         :log_elements,
         :onentry_actions,
         :onexit_actions,
         :parallel_states,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "history"
  test "test580" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p1" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <parallel id="p1">
            <onentry>
                <send delay="2s" event="timeout" />
            </onentry>
            <state id="s0">
                <transition cond="In('sh1')" target="fail" />
                <transition event="timeout" target="fail" />
            </state>
            <state id="s1">
                <initial>
                    <transition target="sh1" />
                </initial>
                <history id="sh1">
                    <transition target="s11" />
                </history>
                <state id="s11">
                    <transition cond="In('sh1')" target="fail" />
                    <transition target="s12" />
                </state>
                <state id="s12" />
                <transition cond="In('sh1')" target="fail" />
                <transition cond="Var1==0" target="sh1" />
                <transition cond="Var1==1" target="pass" />
                <onexit>
                    <assign location="Var1" expr="Var1 + 1" />
                </onexit>
            </state>
        </parallel>
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
      "It follows from the semantics of history states that they never end up in the state configuration"

    test_scxml(xml, description, ["pass"], [])
  end
end
