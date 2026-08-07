defmodule Statifier.Document.InitialTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Initial
  alias Statifier.Document.Transition
  alias Statifier.Parser.Location

  defp loc(offset \\ 0) do
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
    # sabotage: drop :location from Initial's @enforce_keys -> struct!(Initial, []) stops raising for :location
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Initial, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Initial's transitions default from [] to nil -> the pattern match on transitions: [] goes red
    test "transitions defaults to an empty list" do
      initial = struct!(Initial, location: loc())

      assert %Initial{transitions: []} = initial
    end
  end

  describe "malformed transition counts (st-l5k.5 check 4)" do
    # sabotage: drop :transitions from Initial's defstruct fields entirely -> red
    test "zero transitions is representable" do
      initial = %Initial{transitions: [], location: loc()}

      assert %Initial{transitions: []} = initial
    end

    # sabotage: drop :transitions from Initial's defstruct fields entirely -> red
    test "two transitions is representable" do
      t1 = %Transition{target: ["s1"], location: loc(1)}
      t2 = %Transition{target: ["s2"], location: loc(2)}

      initial = %Initial{transitions: [t1, t2], location: loc()}

      assert %Initial{transitions: [%Transition{target: ["s1"]}, %Transition{target: ["s2"]}]} =
               initial
    end
  end
end
