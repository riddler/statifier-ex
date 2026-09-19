# Generated from conformance/corpus/w3c.json, case w3c/test411, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 411/test411.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SelectingTransitions.Test411 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :if_elements,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_delay_expressions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "SelectingTransitions"
  test "test411" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="1s" />
                <if cond="In('s01')">
                    <raise event="event1" />
                </if>
            </onentry>
            <transition event="timeout" target="fail" />
            <transition event="event1" target="fail" />
            <transition event="event2" target="pass" />
            <state id="s01">
                <onentry>
                    <if cond="In('s01')">
                        <raise event="event2" />
                    </if>
                </onentry>
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
      "To enter a state, the SCXML Processor MUST add the state to the active state's list. Then it MUST execute the executable content in the state's onentry handler."

    test_scxml(xml, description, ["pass"], [])
  end
end
