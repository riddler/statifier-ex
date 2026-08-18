defmodule Statifier.Document.StateTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.{Donedata, Initial, State}
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
    # sabotage: drop :kind from State's @enforce_keys -> struct!(State, []) stops raising for :kind
    test "struct!/2 with no fields raises ArgumentError naming :kind and :location" do
      assert_raise ArgumentError, ~r/:kind/, fn -> struct!(State, []) end
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(State, []) end
    end

    # sabotage: drop :location from State's @enforce_keys -> struct!(State, kind: :state) stops raising for :location
    test "struct!/2 with only :kind raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(State, kind: :state) end
    end
  end

  describe "defaults" do
    # sabotage: change State's states default from [] to nil -> the pattern match on states: [] goes red
    test "every collection defaults to [], attribute_locations to %{}, the rest to nil" do
      state = struct!(State, kind: :state, location: loc())

      assert %State{
               id: nil,
               initial: [],
               initial_element: nil,
               states: [],
               transitions: [],
               onentry: [],
               onexit: [],
               history_type: nil,
               donedata: nil,
               attribute_locations: %{}
             } = state
    end
  end

  describe "the four kinds" do
    # sabotage: drop :kind from State's defstruct fields entirely -> red
    test "each kind constructs" do
      assert %State{kind: :state} = %State{kind: :state, location: loc()}
      assert %State{kind: :parallel} = %State{kind: :parallel, location: loc()}
      assert %State{kind: :final} = %State{kind: :final, location: loc()}
      assert %State{kind: :history} = %State{kind: :history, location: loc()}
    end
  end

  describe "nested composition" do
    # sabotage: drop :states from State's defstruct fields entirely -> red
    test "a nested fixture round-trips child order" do
      inner_state = %State{kind: :state, id: "s1a", location: loc(4)}
      inner_history = %State{kind: :history, id: "h1", location: loc(5)}

      parallel = %State{
        kind: :parallel,
        id: "p1",
        states: [inner_state, inner_history],
        location: loc(3)
      }

      root =
        %State{
          kind: :state,
          id: "root",
          states: [parallel],
          location: loc(0)
        }

      assert %State{
               kind: :state,
               id: "root",
               states: [
                 %State{
                   kind: :parallel,
                   id: "p1",
                   states: [
                     %State{kind: :state, id: "s1a"},
                     %State{kind: :history, id: "h1"}
                   ]
                 }
               ]
             } = root
    end
  end

  describe "malformed shapes are representable" do
    # sabotage: drop :states from State's defstruct fields entirely -> red
    test "a :final with a states child (check 6)" do
      child = %State{kind: :state, id: "s1", location: loc(1)}
      final = %State{kind: :final, states: [child], location: loc(0)}

      assert %State{kind: :final, states: [%State{kind: :state, id: "s1"}]} = final
    end

    # sabotage: drop :donedata from State's defstruct fields entirely -> red
    test "a :state with donedata (check 8)" do
      donedata = %Donedata{location: loc(1)}
      state = %State{kind: :state, donedata: donedata, location: loc(0)}

      assert %State{kind: :state, donedata: %Donedata{}} = state
    end

    # sabotage: drop :initial_element from State's defstruct fields -> red
    test "a :state with both initial and initial_element (check 4)" do
      initial_element = %Initial{location: loc(1)}

      state = %State{
        kind: :state,
        initial: ["s1"],
        initial_element: initial_element,
        location: loc(0)
      }

      assert %State{kind: :state, initial: ["s1"], initial_element: %Initial{}} = state
    end

    # sabotage: drop :history_type from State's defstruct fields -> red
    test "a :history under a :final (check 5)" do
      history = %State{kind: :history, history_type: :shallow, location: loc(1)}
      final = %State{kind: :final, states: [history], location: loc(0)}

      assert %State{kind: :final, states: [%State{kind: :history, history_type: :shallow}]} =
               final
    end
  end
end
