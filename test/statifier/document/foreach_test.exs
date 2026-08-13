defmodule Statifier.Document.ForeachTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Foreach
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
    # sabotage: drop :array from Foreach's @enforce_keys -> red
    test "struct!/2 with only :location raises ArgumentError naming :array and :item" do
      assert_raise ArgumentError, ~r/:array/, fn -> struct!(Foreach, location: loc()) end
    end

    # sabotage: drop :item from Foreach's @enforce_keys -> red
    test "struct!/2 with :location and :array raises ArgumentError naming :item" do
      assert_raise ArgumentError, ~r/:item/, fn ->
        struct!(Foreach, location: loc(), array: "items")
      end
    end
  end

  describe "defaults" do
    # sabotage: change Foreach's index default from nil to "" -> red
    test "index defaults to nil" do
      foreach = struct!(Foreach, location: loc(), array: "items", item: "x")

      assert %Foreach{index: nil} = foreach
    end

    # sabotage: change Foreach's content default from [] to nil -> red
    test "content defaults to []" do
      foreach = struct!(Foreach, location: loc(), array: "items", item: "x")

      assert %Foreach{content: []} = foreach
    end

    # sabotage: change Foreach's attribute_locations default from %{} to nil -> red
    test "attribute_locations defaults to %{}" do
      foreach = struct!(Foreach, location: loc(), array: "items", item: "x")

      assert %Foreach{attribute_locations: %{}} = foreach
    end
  end

  describe "location is the <foreach> element's own span" do
    # sabotage: n/a - this test pins the struct's own field-type contract
    # (`location` is the whole `<foreach>` element's span, with no
    # `node_location` rename the way `%Document.Assign{}` needs), which a
    # single-line lib/ mutation cannot plausibly violate on its own; the
    # actual span this contract exists for is exercised by
    # `lowering/content_test.exs`'s `<foreach>` happy-path test, which
    # asserts `location` against a real parsed document.
    test "location is independent of array/item, and reads back unchanged" do
      foreach_location = loc()

      foreach = %Foreach{location: foreach_location, array: "items", item: "x"}

      assert foreach.location == foreach_location
    end
  end
end
