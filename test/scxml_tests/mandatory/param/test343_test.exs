# Generated from conformance/corpus/w3c.json, case w3c/test343, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 343/test343.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Param.Test343 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :conditional_transitions,
         :donedata_elements,
         :event_transitions,
         :eventless_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "param"
  test "test343" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
        <state id="s0" initial="s01">
            <transition event="error.execution" target="s1" />
            <transition event="done.state.s0" target="fail" />
            <transition event="done.state.s0" target="fail" />
            <state id="s01">
                <transition target="s02" />
            </state>
            <final id="s02">
                <donedata>
                    <param location="foo.bar.baz " name="someParam" />
                </donedata>
            </final>
        </state>
        <state id="s1">
            <transition event="done.state.s0" cond="_event.data === undefined" target="pass" />
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
      "If the 'location' attribute on a param element does not refer to a valid location in the data model, or if the evaluation of the 'expr' produces an error, the processor MUST ignore the name and value."

    test_scxml(xml, description, ["pass"], [])
  end
end
