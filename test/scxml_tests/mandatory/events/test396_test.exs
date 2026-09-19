# Generated from conformance/corpus/w3c.json, case w3c/test396, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 396/test396.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Events.Test396 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :conditional_transitions,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements
       ]
  @tag conformance: "mandatory", spec: "events"
  test "test396" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0">
        <state id="s0">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="foo" cond="_event.name == 'foo'" target="pass" />
            <transition event="foo" target="fail" />
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
      "The SCXML processor MUST use this same name value [the one reflected in the event variable] to match against the 'event' attribute of transitions."

    test_scxml(xml, description, ["pass"], [])
  end
end
