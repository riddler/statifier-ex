defmodule Statifier.Document.TransitionTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Transition
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
    # sabotage: drop :location from Transition's @enforce_keys -> struct!(Transition, []) stops raising for :location
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Transition, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Transition's type default from :external to :internal -> red
    test "event and target default to [], type to :external, cond to nil" do
      transition = struct!(Transition, location: loc())

      assert %Transition{
               event: [],
               cond: nil,
               target: [],
               type: :external,
               content: [],
               attribute_locations: %{}
             } = transition
    end
  end

  describe "list attributes" do
    # sabotage: drop :event from Transition's defstruct fields entirely -> red
    test "event and target hold already-split lists of strings" do
      transition = %Transition{
        event: ["a.b", "c"],
        target: ["s1", "s2"],
        location: loc()
      }

      assert %Transition{event: ["a.b", "c"], target: ["s1", "s2"]} = transition
    end

    # sabotage: drop :target from Transition's defstruct fields entirely -> red
    test "no field holds an unsplit whitespace-bearing descriptor string" do
      transition = %Transition{
        event: ["a.b", "c"],
        target: ["s1", "s2"],
        location: loc()
      }

      refute Enum.any?(transition.event, &String.contains?(&1, " "))
      refute Enum.any?(transition.target, &String.contains?(&1, " "))
    end
  end

  describe "defaults-vs-written" do
    # sabotage: drop :attribute_locations from Transition's defstruct fields -> red
    test "a defaulted type is distinguishable from a written one" do
      defaulted = %Transition{type: :external, location: loc()}
      written = %Transition{type: :external, location: loc(), attribute_locations: %{type: loc()}}

      refute Map.has_key?(defaulted.attribute_locations, :type)
      assert Map.has_key?(written.attribute_locations, :type)
    end
  end

  describe "attribute_locations" do
    # sabotage: drop :cond from Transition's defstruct fields entirely -> red
    test "attribute_locations[:cond] holds the cond value span" do
      transition = %Transition{
        cond: "x > 1",
        location: loc(),
        attribute_locations: %{cond: loc()}
      }

      assert Map.has_key?(transition.attribute_locations, :cond)
      refute Map.has_key?(transition.attribute_locations, :event)
    end
  end
end
