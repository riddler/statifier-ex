# Generated from conformance/corpus/w3c.json, case w3c/test207, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 207/test207.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.Cancel.Test207 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :basic_states,
         :cancel_elements,
         :compound_states,
         :event_transitions,
         :final_states,
         :invoke_elements,
         :log_elements,
         :onentry_actions,
         :send_content_elements,
         :send_delay_expressions,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "cancel"
  test "test207" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0" initial="s01">
            <onentry>
                <send event="timeout" delayexpr="'2s'" />
            </onentry>
            <invoke type="scxml">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator">
                        <state id="sub0">
                            <onentry>
                                <send event="event1" id="foo" delayexpr="'1s'" />
                                <send event="event2" delayexpr="'1.5s'" />
                                <send target="#_parent" event="childToParent" />
                            </onentry>
                            <transition event="event1" target="subFinal">
                                <send target="#_parent" event="pass" />
                            </transition>
                            <transition event="*" target="subFinal">
                                <send target="#_parent" event="fail" />
                            </transition>
                        </state>
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <state id="s01">
                <transition event="childToParent" target="s02">
                    <cancel sendid="foo" />
                </transition>
            </state>
            <state id="s02">
                <transition event="pass" target="pass" />
                <transition event="fail" target="fail" />
                <transition event="timeout" target="fail" />
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
      "The SCXML Processor MUST NOT allow cancel to affect events that were not raised in the same session."

    test_scxml(xml, description, ["pass"], [])
  end
end
