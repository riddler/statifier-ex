defmodule Statifier.Document.IfTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.If
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
    # sabotage: drop :location from If's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(If, []) end
    end

    # sabotage: drop :location from If.Branch's @enforce_keys -> red
    test "Branch struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(If.Branch, []) end
    end
  end

  describe "defaults" do
    # sabotage: change If's branches default from [] to nil -> red
    test "branches defaults to []" do
      if_node = struct!(If, location: loc())

      assert %If{branches: []} = if_node
    end

    # sabotage: change Branch's cond default from nil to "" -> red
    test "Branch defaults: cond is nil, content is [], attribute_locations is %{}" do
      branch = struct!(If.Branch, location: loc())

      assert %If.Branch{cond: nil, content: [], attribute_locations: %{}} = branch
    end
  end

  describe "attribute_locations" do
    # sabotage: n/a - this test builds `%If.Branch{}` by hand rather than
    # through any lib/ builder, so it pins the struct's own field-presence
    # contract (a plain `Map.has_key?/2` check), the same way
    # `assign_test.exs`'s "location versus node_location" test is exempt;
    # no single-line lib/ mutation reaches a hand-built literal. The actual
    # write-vs-default distinction this contract exists for is exercised by
    # `lowering/content_test.exs`'s `<if>`/`<elseif>` happy-path tests,
    # which build a branch's `attribute_locations` through the real
    # `build_if/2`/`build_elseif/2` pipeline.
    test "a populated attribute_locations distinguishes a written key from an absent one" do
      branch = %If.Branch{
        location: loc(),
        cond: "x > 1",
        attribute_locations: %{cond: loc()}
      }

      assert Map.has_key?(branch.attribute_locations, :cond)
      refute Map.has_key?(branch.attribute_locations, :missing)
    end
  end

  describe "branches carry their own partitioning tag's location" do
    # sabotage: n/a - this test pins the struct's own field-type contract
    # (each branch's `location` is that branch's own tag span, not the
    # `<if>`'s overall span), which a single-line lib/ mutation cannot
    # plausibly violate on its own; the actual partitioning behavior this
    # contract exists for is exercised (and sabotaged) by
    # `lowering/content_test.exs`'s `<if>` happy-path test, which asserts
    # each branch's `location` and content together against a real document.
    test "an If's own location and a branch's location are independent fields" do
      if_location = loc()
      branch_location = %{loc() | start_offset: 99}

      if_node = %If{
        location: if_location,
        branches: [%If.Branch{location: branch_location, cond: "true"}]
      }

      assert if_node.location == if_location
      assert [%If.Branch{location: ^branch_location}] = if_node.branches
    end
  end
end
