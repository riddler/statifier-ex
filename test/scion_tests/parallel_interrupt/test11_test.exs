# Generated from conformance/corpus/scion.json, case
# scion/parallel+interrupt/test11, by tools/corpus/scion/cases.exs. Regenerate
# with `mise run corpus:emit`; never edit by hand.
#
# The document in this test is test/parallel+interrupt/test11.scxml from the
# SCION scxml-test-framework
# (https://github.com/jbeard4/scxml-test-framework), licensed under
# Apache-2.0; the licence text is conformance/LICENSES/Apache-2.0.txt.
defmodule SCIONTest.ParallelInterrupt.Test11Test do
  use Statifier.Case, async: true

  @moduletag :scion
  @tag required_features: [:basic_states, :compound_states, :event_transitions, :parallel_states]
  @tag spec: "parallel+interrupt"
  test "test11" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- 
    initial: [b1,b2]
    after t: [d]
    --> 
    <scxml
        datamodel="ecmascript"
        xmlns="http://www.w3.org/2005/07/scxml"
        version="1.0"
        initial="a">

        <state id="a" initial="b">

            <parallel id="b">
                <state id="b1">
                    <transition event="t" target="d"/>
                </state>

                <state id="b2">
                    <transition event="t" target="c"/>
                </state>

            </parallel>

            <parallel id="c">
                <state id="c1">
                </state>

                <state id="c2">
                </state>
            </parallel>

        </state>

        <state id="d"/>

    </scxml>
    """

    test_scxml(xml, "", ["b1", "b2"], [{%{"name" => "t"}, ["d"]}])
  end
end
