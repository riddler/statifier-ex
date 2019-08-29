defmodule Exstate.ScxmlParser do
  import SweetXml

  def parse xml_string do
    xml = SweetXml.parse xml_string
    initial_state = SweetXml.xpath xml, ~x"/scxml/@initial"s
    Exstate.Machine.new initial_state
  end
end
