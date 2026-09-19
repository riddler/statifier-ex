# Generated from conformance/corpus/w3c.json, case w3c/test148, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 148/test148.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.If.Test148 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :final_states,
         :if_elements,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "if"
  test "test148" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <if cond="false">
                    <raise event="foo" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <elseif cond="false" />
                    <raise event="bar" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <else />
                    <raise event="baz" />
                    <assign location="Var1" expr="Var1 + 1" />
                </if>
                <raise event="bat" />
            </onentry>
            <transition event="baz" cond="Var1==1" target="pass" />
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
      "When the if element is executed, if no 'cond'attribute evaluates to true, the SCXML Processor must execute the partition defined by the else tag, if there is one."

    test_scxml(xml, description, ["pass"], [])
  end
end
