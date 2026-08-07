defmodule Statifier.Document.RaiseTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Raise
  alias Statifier.Parser.Location

  defp loc do
    %Location{
      start_line: 1,
      start_column: 1,
      start_offset: 0,
      end_line: 1,
      end_column: 10,
      end_offset: 9
    }
  end

  describe "@enforce_keys" do
    # sabotage: drop :event from Raise's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :event and :location" do
      assert_raise ArgumentError, ~r/:event/, fn -> struct!(Raise, []) end
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Raise, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Raise's attribute_locations default from %{} to nil -> red
    test "attribute_locations defaults to an empty map" do
      raise_ = struct!(Raise, event: "go", location: loc())

      assert %Raise{attribute_locations: %{}} = raise_
    end
  end

  describe "attribute_locations" do
    # sabotage: drop attribute_locations from Raise's defstruct fields -> red
    test "distinguishes a written attribute from an absent one" do
      raise_ = %Raise{event: "go", location: loc(), attribute_locations: %{event: loc()}}

      assert Map.has_key?(raise_.attribute_locations, :event)
      refute Map.has_key?(raise_.attribute_locations, :cond)
    end
  end
end
