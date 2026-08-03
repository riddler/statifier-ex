defmodule SCXMLTest.Invoke.Test239sub1 do
  use Statifier.Case

  @moduletag :scxml_w3
  @tag required_features: [:final_states]
  @tag conformance: "mandatory", spec: "invoke"
  test "test239sub1" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="final" version="1.0" datamodel="predicator">
        <final id="final" />
    </scxml>
    """

    description =
      "Invoked services of type http://www.w3.org/TR/scxml/, http://www.w3.org/TR/ccxml/, http://www.w3.org/TR/voicexml30/, or http://www.w3.org/TR/voicexml21 MUST interpret values specified by the content element or 'src' attribute as markup to be executed"

    test_scxml(xml, description, ["pass"], [])
  end
end
