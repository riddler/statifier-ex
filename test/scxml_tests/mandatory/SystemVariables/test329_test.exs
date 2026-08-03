defmodule SCXMLTest.SystemVariables.Test329 do
  use Statifier.Case

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
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test329" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator" name="machineName">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" />
            <data id="Var3" />
            <data id="Var4" />
        </datamodel>
        <state id="s0">
            <onentry>
                <raise event="foo" />
                <assign location="Var1" expr="_sessionid" />
                <assign location="_sessionid" expr="27" />
            </onentry>
            <transition event="foo" cond="Var1==_sessionid" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <assign location="Var2" expr="_event" />
                <assign location="_event" expr="27" />
            </onentry>
            <transition cond="Var2==_event" target="s2" />
            <transition target="fail" />
        </state>
        <state id="s2">
            <onentry>
                <assign location="Var3" expr="_name" />
                <assign location="_name" expr="27" />
            </onentry>
            <transition cond="Var3==_name" target="s3" />
            <transition target="fail" />
        </state>
        <state id="s3">
            <onentry>
                <assign location="Var4" expr="_ioprocessors" />
                <assign location="_ioprocessors" expr="27" />
            </onentry>
            <transition cond="Var4==_ioprocessors" target="pass" />
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
      "The Processor MUST cause any attempt to change the value of a system variable to fail."

    test_scxml(xml, description, ["pass"], [])
  end
end
