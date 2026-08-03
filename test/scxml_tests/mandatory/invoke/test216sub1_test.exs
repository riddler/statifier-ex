defmodule SCXMLTest.Invoke.Test216sub1 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [:final_states]
  @tag conformance: "mandatory", spec: "invoke"
  test "test216sub1" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="final" version="1.0" datamodel="predicator">
        <final id="final" />
    </scxml>
    """

    description =
      "If the srcexpr attribute is present, the SCXML Processor MUST evaluate it when the parent invoke element is evaluated and treat the result as if it had been entered as the value of 'src'."

    test_scxml(xml, description, ["pass"], [])
  end
end
