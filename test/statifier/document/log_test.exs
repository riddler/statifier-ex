defmodule Statifier.Document.LogTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Log
  alias Statifier.Parser.Location

  defp loc do
    %Location{
      start_line: 2,
      start_column: 3,
      start_offset: 10,
      end_line: 2,
      end_column: 20,
      end_offset: 27
    }
  end

  describe "@enforce_keys" do
    # sabotage: drop :location from Log's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Log, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Log's label default from nil to "" -> red
    test "label and expr default to nil, never the empty string" do
      log = struct!(Log, location: loc())

      assert %Log{label: nil, expr: nil, attribute_locations: %{}} = log
    end
  end

  describe "attribute_locations" do
    # sabotage: drop :expr from Log's defstruct fields entirely -> red
    # (struct literal below fails to compile, unknown key :expr)
    test "a populated attribute_locations distinguishes a written key from an absent one" do
      log = %Log{
        expr: "x > 1",
        location: loc(),
        attribute_locations: %{expr: loc()}
      }

      assert Map.has_key?(log.attribute_locations, :expr)
      refute Map.has_key?(log.attribute_locations, :label)
    end
  end
end
