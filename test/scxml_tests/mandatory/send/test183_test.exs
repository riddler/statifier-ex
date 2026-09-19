# Generated from conformance/corpus/w3c.json, case w3c/test183, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 183/test183.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Send.Test183 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :send_elements,
         :send_idlocation
       ]
  @tag conformance: "mandatory", spec: "send"
  test "test183" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="event1" idlocation="Var1" />
            </onentry>
            <transition cond="Var1 !== undefined" target="pass" />
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
      "If 'idlocation' is present, the SCXML Processor MUST generate an id when the parent send element is evaluated and store it in this location"

    test_scxml(xml, description, ["pass"], [])
  end
end
