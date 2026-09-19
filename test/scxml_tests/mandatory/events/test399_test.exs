# Generated from conformance/corpus/w3c.json, case w3c/test399, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 399/test399.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Events.Test399 do
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
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "events"
  test "test399" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <transition event="timeout" target="fail" />
            <state id="s01">
                <onentry>
                    <raise event="foo" />
                </onentry>
                <transition event="foo bar" target="s02" />
            </state>
            <state id="s02">
                <onentry>
                    <raise event="bar" />
                </onentry>
                <transition event="foo bar" target="s03" />
            </state>
            <state id="s03">
                <onentry>
                    <raise event="foo.zoo" />
                </onentry>
                <transition event="foo bar" target="s04" />
            </state>
            <state id="s04">
                <onentry>
                    <raise event="foos" />
                </onentry>
                <transition event="foo" target="fail" />
                <transition event="foos" target="s05" />
            </state>
            <state id="s05">
                <onentry>
                    <raise event="foo.zoo" />
                </onentry>
                <transition event="foo.*" target="s06" />
            </state>
            <state id="s06">
                <onentry>
                    <raise event="foo" />
                </onentry>
                <transition event="*" target="pass" />
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
      "[Definition: A transition matches an event if at least one of its event descriptors matches the event's name. ] [Definition: An event descriptor matches an event name if its string of tokens is an exact match or a prefix of the set of tokens in the event's name. In all cases, the token matching is case sensitive. ]"

    test_scxml(xml, description, ["pass"], [])
  end
end
