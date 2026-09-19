# Generated from conformance/corpus/w3c.json, case w3c/test338, by
# tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`;
# never edit by hand.
#
# The document in this test is transformed for the predicator datamodel from
# 338/test338.txml of the W3C SCXML Implementation Report Plan test suite
# (https://www.w3.org/Voice/2013/scxml-irp/).
#
# Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved.
#
# Redistributed under BSD-3-Clause-W3C, the W3C 3-clause BSD License; its
# conditions and disclaimer are in conformance/LICENSES/BSD-3-Clause-W3C.txt.
defmodule SCXMLTest.SystemVariables.Test338 do
  use Statifier.Case, async: true

  @moduletag :scxml_w3
  @tag required_features: [
         :assign_elements,
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
         :send_idlocation
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test338" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" />
        </datamodel>
        <state id="s0">
            <onentry>
                <send event="timeout" delay="2s" />
            </onentry>
            <invoke idlocation="Var1" type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="sub0" version="1.0" datamodel="predicator" name="machineName">
                        <final id="sub0">
                            <onentry>
                                <send target="#_parent" event="event1" />
                            </onentry>
                        </final>
                    </scxml>
                </content>
            </invoke>
            <transition event="event1" target="s1">
                <assign location="Var2" expr="_event.invokeid" />
            </transition>
            <transition event="event0" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var1===Var2" target="pass" />
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
      "If an event is generated from an invoked child process, the Processor MUST set the invokeid field to the invoke id of the invocation that triggered the child process."

    test_scxml(xml, description, ["pass"], [])
  end
end
