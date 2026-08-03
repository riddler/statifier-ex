defmodule SCXMLTest.Invoke.Test242sub1 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [:final_states]
  @tag conformance: "mandatory", spec: "invoke"
  test "test242sub1" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="final" version="1.0" datamodel="predicator">
        <final id="final" />
    </scxml>
    """

    description =
      "Invoked services MUST also treat values specified by 'src' and content identically."

    test_scxml(xml, description, ["pass"], [])
  end
end
