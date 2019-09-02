defmodule Staart do
  @moduledoc """
  Documentation for Staart.
  """

  def machine_from_file path do
    {:ok, xmldoc} = File.read Path.expand path
    statechart = Staart.Scxml.parse_statechart xmldoc
    Staart.Machine.new statechart
  end
end
