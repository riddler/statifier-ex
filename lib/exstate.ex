defmodule Exstate do
  alias Exstate.Scxml

  @moduledoc """
  Documentation for Exstate.
  """

  #@doc """
  #Parses SCXML document

  ### Examples

  #    iex> Exstate.parse_scxml "basic.scxml"
  #    :world

  #"""
  def parse_file path do
    {:ok, xmldoc} = File.read Path.expand path
    __MODULE__.parse_xml xmldoc
  end

  def parse_xml xmldoc do
    Scxml.parse xmldoc
  end

  def machine_from_file path do
    {:ok, xmldoc} = File.read Path.expand path
    statechart = Exstate.Scxml.parse_statechart xmldoc
    Exstate.Machine.new statechart
  end
end
