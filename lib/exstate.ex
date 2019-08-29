defmodule Exstate do
  alias Exstate.ScxmlParser

  @moduledoc """
  Documentation for Exstate.
  """

  #@doc """
  #Parses SCXML document

  ### Examples

  #    iex> Exstate.parse_scxml "basic.scxml"
  #    :world

  #"""
  def parse_scxml path do
    {:ok, xmldoc} = File.read Path.expand path
    ScxmlParser.parse xmldoc
  end
end
