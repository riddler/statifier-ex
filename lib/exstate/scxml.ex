defmodule Exstate.Scxml do
  import SweetXml

  def parse xml_string do
    xml = SweetXml.parse xml_string
    root_element = SweetXml.xpath xml, ~x"/scxml"
    state_node root_element
  end

  def state_node xml do
    initial = xml |> xpath(~x"./@initial"s)
    id = xml |> xpath(~x"./@id"s)

    transitions = xml
                  |> xpath(~x"./transition"l,
                    target: ~x"./@target"s,
                    event: ~x"./@event"s
                  )
    states = xml
      |> xpath(~x"./state"l)
      |> Enum.map(fn (state_element) -> state_node(state_element) end)

    Exstate.StateNode.new id, initial, states, transitions
  end
end
