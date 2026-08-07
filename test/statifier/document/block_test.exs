defmodule Statifier.Document.BlockTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Block
  alias Statifier.Document.Log
  alias Statifier.Document.Raise
  alias Statifier.Parser.Location

  defp loc(offset) do
    %Location{
      start_line: 1,
      start_column: offset + 1,
      start_offset: offset,
      end_line: 1,
      end_column: offset + 2,
      end_offset: offset + 1
    }
  end

  describe "@enforce_keys" do
    # sabotage: drop :location from Block's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Block, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Block's content default from [] to nil -> red
    test "content defaults to an empty list" do
      block = struct!(Block, location: loc(0))

      assert %Block{content: []} = block
    end
  end

  describe "content order" do
    # sabotage: drop :content from Block's defstruct fields entirely -> red
    # (struct literal below fails to compile, unknown key :content)
    test "a Raise and a Log round-trip source order" do
      raise_ = %Raise{event: "go", location: loc(1)}
      log = %Log{expr: "1 > 0", location: loc(2)}

      block = %Block{content: [raise_, log], location: loc(0)}

      assert %Block{content: [%Raise{event: "go"}, %Log{expr: "1 > 0"}]} = block
    end
  end
end
