defmodule Exstate.Scxml do
  import SweetXml

  # Return a map of the statechart
  def parse_statechart xml_string do
    xml_string
    |> SweetXml.parse
    |> SweetXml.xpath(~x"/scxml")
    |> xml_to_map
    |> Exstate.Statechart.new
  end

  def xml_to_map xml do
    initial = xml |> xpath(~x"./@initial"s)
    id = xml |> xpath(~x"./@id"s)

    transitions = xml
                  |> xpath(~x"./transition"l,
                    target: ~x"./@target"s,
                    event: ~x"./@event"s
                  )
    states = xml
      |> xpath(~x"./state"l)
      |> Enum.map(fn (state_element) -> xml_to_map(state_element) end)

    %{
      id: id,
      initial: initial,
      transitions: transitions,
      states: states
    }
  end
end
