# Generated from conformance/corpus/w3c.json, case w3c/test421, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 421/test421.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SelectingTransitions.Test421 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_elements
       ]
  @tag conformance: "mandatory", spec: "SelectingTransitions"
  test "test421" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1" datamodel="predicator">
        <state id="s1" initial="s11">
            <onentry>
                <send event="externalEvent" />
                <raise event="internalEvent1" />
                <raise event="internalEvent2" />
                <raise event="internalEvent3" />
                <raise event="internalEvent4" />
            </onentry>
            <transition event="externalEvent" target="fail" />
            <state id="s11">
                <transition event="internalEvent3" target="s12" />
            </state>
            <state id="s12">
                <transition event="internalEvent4" target="pass" />
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
      "If the set (of eventless transitions) is empty, the Processor MUST remove events from the internal event queue until the queue is empty or it finds an event that enables a non-empty optimal transition set in the current configuration. If it finds such a set [a non-empty optimal transition set], the processor MUST then execute it as a microstep."

    test_scxml(xml, description, ["pass"], [])
  end
end
