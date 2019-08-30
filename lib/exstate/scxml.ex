defmodule Exstate.Scxml do
  import SweetXml

  # Return a map of the statechart
  def parse_statechart xml_string do
    xml = SweetXml.parse xml_string
    root_element = SweetXml.xpath xml, ~x"/scxml"
    sc_map root_element
  end

  def sc_map xml do
    initial = xml |> xpath(~x"./@initial"s)
    id = xml |> xpath(~x"./@id"s)

    transitions = xml
                  |> xpath(~x"./transition"l,
                    target: ~x"./@target"s,
                    event: ~x"./@event"s
                  )
    states = xml
      |> xpath(~x"./state"l)
      |> Enum.map(fn (state_element) -> sc_map(state_element) end)

    %{
      id: id,
      initial: initial,
      transitions: transitions,
      states: states
    }
  end

  #def parse xml_string do
  #  xml = SweetXml.parse xml_string
  #  root_element = SweetXml.xpath xml, ~x"/scxml"
  #  state_node root_element
  #end

  #def state_node xml do
  #  initial = xml |> xpath(~x"./@initial"s)
  #  id = xml |> xpath(~x"./@id"s)

  #  transitions = xml
  #                |> xpath(~x"./transition"l,
  #                  target: ~x"./@target"s,
  #                  event: ~x"./@event"s
  #                )
  #  states = xml
  #    |> xpath(~x"./state"l)
  #    |> Enum.map(fn (state_element) -> state_node(state_element) end)

  #  Exstate.StateNode.new id, initial, states, transitions
  #end
end
