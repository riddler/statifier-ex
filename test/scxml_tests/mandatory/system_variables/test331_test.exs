defmodule SCXMLTest.SystemVariables.Test331 do
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
         :log_elements,
         :onentry_actions,
         :raise_elements,
         :send_elements,
         :wildcard_events
       ]
  @tag conformance: "mandatory", spec: "SystemVariables"
  test "test331" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0" name="machineName">
        <datamodel>
            <data id="Var1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <raise event="foo" />
            </onentry>
            <transition event="foo" target="s1">
                <assign location="Var1" expr="_event.type" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <transition cond="Var1=='internal'" target="s2" />
            <transition target="fail" />
        </state>
        <state id="s2">
            <onentry>
                <assign location="foo.bar.baz " expr="1" />
            </onentry>
            <transition event="error" target="s3">
                <assign location="Var1" expr="_event.type" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s3">
            <transition cond="Var1=='platform'" target="s4" />
            <transition target="fail" />
        </state>
        <state id="s4">
            <onentry>
                <send event="foo" />
            </onentry>
            <transition event="foo" target="s5">
                <assign location="Var1" expr="_event.type" />
            </transition>
            <transition event="*" target="fail" />
        </state>
        <state id="s5">
            <transition cond="Var1=='external'" target="pass" />
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
      "The SCXML Processor MUST set the type property of _event to: \"platform\" (for events raised by the platform itself, such as error events), \"internal\" (for events raised by raise and send with target '_internal') or \"external\" (for all other events)."

    test_scxml(xml, description, ["pass"], [])
  end
end
