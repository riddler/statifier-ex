defmodule Statifier.Document.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Content
  alias Statifier.Parser.Location

  defp loc do
    %Location{
      start_line: 1,
      start_column: 1,
      start_offset: 0,
      end_line: 1,
      end_column: 5,
      end_offset: 4
    }
  end

  describe "@enforce_keys" do
    # sabotage: drop :location from Content's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Content, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Content's text default from nil to "" -> red
    test "expr and text default to nil, never the empty string" do
      content = struct!(Content, location: loc())

      assert %Content{expr: nil, text: nil, attribute_locations: %{}} = content
    end
  end

  describe "expr and text together" do
    # sabotage: drop :expr from Content's defstruct fields entirely -> red
    # (struct literal below fails to compile, unknown key :expr)
    test "both expr and text are representable on the same node" do
      content = %Content{expr: "x", text: "hello", location: loc()}

      assert %Content{expr: "x", text: "hello"} = content
    end
  end

  describe "attribute_locations" do
    # sabotage: drop :attribute_locations from Content's defstruct -> red
    # (struct literal below fails to compile, unknown key :attribute_locations)
    test "a populated attribute_locations distinguishes a written key from an absent one" do
      content = %Content{expr: "x", location: loc(), attribute_locations: %{expr: loc()}}

      assert Map.has_key?(content.attribute_locations, :expr)
      refute Map.has_key?(content.attribute_locations, :text)
    end
  end
end
