# Generated from conformance/corpus/w3c.json, case w3c/test346, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 346/test346.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SystemVariables.Test346 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
         :basic_states,
         :compound_states,
         :event_transitions,
         :final_states,
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :targetless_transitions,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test346" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator" name="machineName">
        <state id="s0">
            <onentry>
                <assign location="_sessionid" expr="'otherName'" />
                <raise event="event1" />
            </onentry>
            <transition event="error.execution" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <assign location="_event" expr="'otherName'" />
                <raise event="event2" />
            </onentry>
            <transition event="event1" />
            <transition event="error.execution" target="s2" />
            <transition event="*" target="fail" />
        </state>
        <state id="s2">
            <onentry>
                <assign location="_ioprocessors" expr="'otherName'" />
                <raise event="event3" />
            </onentry>
            <transition event="event2" />
            <transition event="error.execution" target="s3" />
            <transition event="*" target="fail" />
        </state>
        <state id="s3">
            <onentry>
                <assign location="_name" expr="'otherName'" />
                <raise event="event4" />
            </onentry>
            <transition event="event3" />
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
      "The Processor MUST place the error error.execution on the internal event queue when any attempt to change the value of a system variable is made."

    test_scxml(xml, description, ["pass"], [])
  end
end
