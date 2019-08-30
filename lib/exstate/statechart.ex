defmodule Exstate.Statechart do
  alias Exstate.Statechart.StateDefinition

  def from_map map do
    StateDefinition.new map[:id], map[:initial], map[:states], map[:transitions]
  end
end
