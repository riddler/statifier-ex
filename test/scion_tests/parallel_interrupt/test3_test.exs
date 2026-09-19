# Generated from conformance/corpus/scion.json, case
# scion/parallel+interrupt/test3, by tools/corpus/scion/cases.exs. Regenerate
# with `mise run corpus:emit`; never edit by hand.
#
# The document in this test is test/parallel+interrupt/test3.scxml from the
# SCION scxml-test-framework
# (https://github.com/jbeard4/scxml-test-framework), licensed under
# Apache-2.0; the licence text is conformance/LICENSES/Apache-2.0.txt.
defmodule SCIONTest.ParallelInterrupt.Test3Test do
  use Statifier.Case, async: true

  @moduletag :scion
  @tag required_features: [:basic_states, :compound_states, :event_transitions, :parallel_states]
  @tag spec: "parallel+interrupt"
  test "test3" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- 
    orthogonal preemption - inner or states interrupt one-another 
    in our semantics, source state is at the same level of hierarchy, so document order will resolve conflict. a1 will win.
    --> 
    <scxml
        datamodel="ecmascript"
        xmlns="http://www.w3.org/2005/07/scxml"
        version="1.0"
        initial="b">

        <parallel id="b">
            <parallel id="c">
                <state id="e">
                    <transition event="t" target="a1"/>
                </state>

                <state id="f">
                    <transition event="t" target="a2"/>
                </state>

                <transition event="t" target="a3"/>
            </parallel>

            <state id="d">
                <transition event="t" target="a4"/>
            </state>

        </parallel>

        <state id="a1"/>

        <state id="a2"/>

        <state id="a3"/>

        <state id="a4"/>

    </scxml>
    """

    test_scxml(xml, "", ["e", "f", "d"], [{%{"name" => "t"}, ["a1"]}])
  end
end
