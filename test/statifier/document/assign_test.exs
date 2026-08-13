defmodule Statifier.Document.AssignTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Assign
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
    # sabotage: drop :location from Assign's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location and :node_location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Assign, []) end
    end

    # sabotage: drop :node_location from Assign's @enforce_keys -> red
    test "struct!/2 with only :location still raises ArgumentError naming :node_location" do
      assert_raise ArgumentError, ~r/:node_location/, fn ->
        struct!(Assign, location: "foo")
      end
    end
  end

  describe "defaults" do
    # sabotage: change Assign's expr default from nil to "" -> red
    test "expr and text default to nil" do
      assign = struct!(Assign, location: "foo.bar", node_location: loc())

      assert %Assign{expr: nil, text: nil, attribute_locations: %{}} = assign
    end
  end

  describe "attribute_locations" do
    # sabotage: drop :expr from Assign's defstruct fields entirely -> red
    test "a populated attribute_locations distinguishes a written key from an absent one" do
      assign = %Assign{
        location: "foo.bar",
        node_location: loc(),
        expr: "1 + 1",
        attribute_locations: %{location: loc(), expr: loc()}
      }

      assert Map.has_key?(assign.attribute_locations, :expr)
      refute Map.has_key?(assign.attribute_locations, :text)
    end
  end

  describe "location versus node_location" do
    # sabotage: n/a - this test pins the struct's own field-type contract
    # (`location` is a raw string, `node_location` is a `%Location{}`), which
    # a single-line lib/ mutation cannot plausibly violate; the field-naming
    # mixup this test guards against is caught structurally elsewhere
    # (`lowering/content_test.exs`'s well-formed `<assign>` lowering test
    # asserts both fields' real values together).
    test "location is a raw path string, node_location is the element's own Location span" do
      assign = %Assign{location: "user.profile.name", node_location: loc()}

      assert is_binary(assign.location)
      assert %Location{} = assign.node_location
    end
  end
end
