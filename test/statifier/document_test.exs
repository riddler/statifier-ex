defmodule Statifier.DocumentTest do
  use ExUnit.Case, async: true

  alias Statifier.Document
  alias Statifier.Document.Block
  alias Statifier.Document.Content
  alias Statifier.Document.Donedata
  alias Statifier.Document.Initial
  alias Statifier.Document.Log
  alias Statifier.Document.Raise
  alias Statifier.Document.State
  alias Statifier.Document.Transition
  alias Statifier.Parser.Location

  # Every node below gets its own offset, so a bug that swaps two nodes'
  # locations (e.g. a copy-paste of one child's location onto a sibling)
  # would surface as a location mismatch rather than passing by coincidence.
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

  # sabotage: change Document's binding default from :early to :late -> red
  test "enforces :location and defaults binding: :early, states/initial to [], attribute_locations to %{}" do
    assert_raise ArgumentError, ~r/:location/, fn -> struct!(Document, []) end

    document = struct!(Document, location: loc(0))

    assert %Document{
             binding: :early,
             states: [],
             initial: [],
             attribute_locations: %{}
           } = document
  end

  # sabotage: n/a - literal composition, already covered by each struct's own sabotage in Phases 1-2
  test "the full supported element set composes into one document tree" do
    raise_ = %Raise{event: "go", location: loc(1)}
    log = %Log{expr: "1 > 0", location: loc(2)}
    onentry = %Block{content: [raise_, log], location: loc(3)}

    initial_transition = %Transition{
      target: ["s1a"],
      location: loc(4)
    }

    initial_element = %Initial{transitions: [initial_transition], location: loc(5)}

    s1 = %State{
      kind: :state,
      id: "s1",
      initial_element: initial_element,
      onentry: [onentry],
      location: loc(6)
    }

    history = %State{
      kind: :history,
      id: "h1",
      history_type: :deep,
      location: loc(7)
    }

    parallel = %State{
      kind: :parallel,
      id: "p1",
      states: [history],
      location: loc(8)
    }

    outer_transition = %Transition{
      event: ["error.foo", "done"],
      target: ["p1", "f1"],
      cond: "x > 1",
      location: loc(9),
      attribute_locations: %{cond: loc(10)}
    }

    s1_with_transition = %State{s1 | transitions: [outer_transition]}

    content = %Content{text: "done", location: loc(11)}
    donedata = %Donedata{content: content, location: loc(12)}

    final = %State{
      kind: :final,
      id: "f1",
      donedata: donedata,
      location: loc(13)
    }

    document = %Document{
      name: "root",
      initial: ["s1"],
      states: [s1_with_transition, parallel, final],
      location: loc(0)
    }

    assert %Document{
             name: "root",
             initial: ["s1"],
             states: [
               %State{
                 kind: :state,
                 id: "s1",
                 initial_element: %Initial{
                   transitions: [%Transition{target: ["s1a"]}]
                 },
                 onentry: [
                   %Block{
                     content: [
                       %Raise{event: "go"},
                       %Log{expr: "1 > 0"}
                     ]
                   }
                 ],
                 transitions: [
                   %Transition{
                     event: ["error.foo", "done"],
                     target: ["p1", "f1"],
                     cond: "x > 1"
                   }
                 ]
               },
               %State{
                 kind: :parallel,
                 id: "p1",
                 states: [%State{kind: :history, id: "h1", history_type: :deep}]
               },
               %State{
                 kind: :final,
                 id: "f1",
                 donedata: %Donedata{content: %Content{text: "done"}}
               }
             ]
           } = document

    [%State{location: s1_loc}, %State{location: p1_loc}, %State{location: f1_loc}] =
      document.states

    assert Enum.uniq([document.location, s1_loc, p1_loc, f1_loc]) == [
             document.location,
             s1_loc,
             p1_loc,
             f1_loc
           ]
  end
end
