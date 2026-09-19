# Generated from conformance/corpus/w3c.json, case w3c/test344, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 344/test344.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Expressions.Test344 do
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
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "Expressions"
  test "test344" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0">
            <transition cond="1" target="fail" />
            <transition target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="error.execution" target="pass" />
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
      "If a conditional expression cannot be evaluated as a boolean value ('true' or 'false') or if its evaluation causes an error, the SCXML processor MUST place the error 'error.execution' in the internal event queue."

    test_scxml(xml, description, ["pass"], [])
  end
end
