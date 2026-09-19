# Generated from conformance/corpus/w3c.json, case w3c/test224, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 224/test224.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Invoke.Test224 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :data_elements,
         :datamodel,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :send_idlocation,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "invoke"
  test "test224" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" expr="'s0.'" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="1s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/" idlocation="Var1">
                <content>
                    <scxml version="1.0" initial="subFinal" datamodel="predicator">
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="*" target="s1" />
        </state>
        <state id="s1">
            <transition cond="starts_with(Var1, Var2)" target="pass" />
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
      "When the platform generates an identifier for 'idlocation', the identifier MUST have the form stateid.platformid, where stateid is the id of the state containing this element and platformid is automatically generated."

    test_scxml(xml, description, ["pass"], [])
  end
end
