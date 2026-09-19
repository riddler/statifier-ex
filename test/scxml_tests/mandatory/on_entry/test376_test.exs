# Generated from conformance/corpus/w3c.json, case w3c/test376, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 376/test376.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.OnEntry.Test376 do
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
         :log_elements,
         :onentry_actions,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "onentry"
  test "test376" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send target="baz" event="event1" />
            </onentry>
            <onentry>
                <assign location="Var1" expr="Var1 + 1" />
            </onentry>
            <transition cond="Var1==2" target="pass" />
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
      "The SCXML processor MUST treat each [onentry] handler as a separate block of executable content."

    test_scxml(xml, description, ["pass"], [])
  end
end
