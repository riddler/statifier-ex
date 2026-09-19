# Generated from conformance/corpus/w3c.json, case w3c/test525, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 525/test525.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Foreach.Test525 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :foreach_elements,
         :log_elements,
         :onentry_actions
       ]
  @tag conformance: "mandatory", spec: "foreach"
  test "test525" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1">[1,2,3]</data>
            <data id="Var2" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var3" array="Var1">
                    <assign location="Var1" expr="concat(Var1, [4])" />
                    <assign location="Var2" expr="Var2 + 1" />
                </foreach>
            </onentry>
            <transition cond="Var2==3" target="pass" />
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

    description =
      "The SCXML processor MUST act as if it has made a shallow copy of the collection produced by the evaluation of 'array'. Specifically, modifications to the collection during the execution of foreach MUST NOT affect the iteration behavior."

    test_scxml(xml, description, ["pass"], [])
  end
end
