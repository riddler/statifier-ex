defmodule Exstate do
  @moduledoc """
  Documentation for Exstate.
  """

  def machine_from_file path do
    {:ok, xmldoc} = File.read Path.expand path
    statechart = Exstate.Scxml.parse_statechart xmldoc
    Exstate.Machine.new statechart
  end
end
