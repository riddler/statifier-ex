# Generated from conformance/corpus/w3c.json, case w3c/test503, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 503/test503.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SelectingTransitions.Test503 do
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
         :log_elements,
         :onentry_actions,
         :onexit_actions,
         :raise_elements,
         :targetless_transitions
       ]
  @tag conformance: "mandatory", spec: "SelectingTransitions"
  test "test503" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s1" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
            <data id="Var2" expr="0" />
        </datamodel>
        <state id="s1">
            <onentry>
                <raise event="foo" />
                <raise event="bar" />
            </onentry>
            <transition target="s2" />
        </state>
        <state id="s2">
            <onexit>
                <assign location="Var1" expr="Var1 + 1" />
            </onexit>
            <transition event="foo">
                <assign location="Var2" expr="Var2 + 1" />
            </transition>
            <transition event="bar" cond="Var2==1" target="s3" />
            <transition event="bar" target="fail" />
        </state>
        <state id="s3">
            <transition cond="Var1==1" target="pass" />
            <transition target="fail" />
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

    description = "If the transition does not contain a 'target', its exit set is empty."

    test_scxml(xml, description, ["pass"], [])
  end
end
