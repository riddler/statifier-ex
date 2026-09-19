# Generated from conformance/corpus/w3c.json, case w3c/test570, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 570/test570.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Final.Test570 do
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
         :final_states,
         :log_elements,
         :onentry_actions,
         :parallel_states,
         :raise_elements,
         :send_delay_expressions,
         :send_elements,
         :targetless_transitions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "final"
  test "test570" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="p0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <parallel id="p0">
            <onentry>
                <send event="timeout" delay="2s" />
                <raise event="e1" />
                <raise event="e2" />
            </onentry>
            <transition event="done.state.p0s1">
                <assign location="Var1" expr="1" />
            </transition>
            <transition event="done.state.p0s2" target="s1" />
            <transition event="timeout" target="fail" />
            <state id="p0s1" initial="p0s11">
                <state id="p0s11">
                    <transition event="e1" target="p0s1final" />
                </state>
                <final id="p0s1final" />
            </state>
            <state id="p0s2" initial="p0s21">
                <state id="p0s21">
                    <transition event="e2" target="p0s2final" />
                </state>
                <final id="p0s2final" />
            </state>
        </parallel>
        <state id="s1">
            <transition event="done.state.p0" cond="Var1==1" target="pass" />
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
      "Immediately after generating done.state.id upon entering a final child of state, if the parent state is a child of a parallel element, and all of the parallel's other children are also in final states, the Processor MUST generate the event done.state.id where id is the id of the parallel element."

    test_scxml(xml, description, ["pass"], [])
  end
end
