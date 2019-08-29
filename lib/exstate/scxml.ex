defmodule Exstate.Scxml do
  import SweetXml

  def parse xml_string do
    xml = SweetXml.parse xml_string
    root_element = SweetXml.xpath xml, ~x"/scxml"
    state_node root_element

    #initial_state = SweetXml.xpath xml, ~x"/scxml/@initial"s
    #Exstate.Machine.new initial_state
  end

  def state_node xml do
    initial = xml |> xpath(~x"./@initial"s)
    id = xml |> xpath(~x"./@id"s)
    states = xml
             |> xpath(~x"./state"l)
             |> Enum.map(fn (state_element) -> state_node(state_element) end)

    Exstate.StateNode.new id, initial, states
  end
end
