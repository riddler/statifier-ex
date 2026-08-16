defmodule Statifier.Lowering.LocationTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Block
  alias Statifier.Document.Content
  alias Statifier.Document.Donedata
  alias Statifier.Document.Initial
  alias Statifier.Document.Log
  alias Statifier.Document.Raise
  alias Statifier.Document.State
  alias Statifier.Document.Transition
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Parser.Location

  # In the style of `test/statifier/parser/location_accuracy_test.exs:13-37`:
  # one document exercising every dispatch-map-supported element,
  # every locatable attribute written so its span can be checked. Every
  # tokenized or enumerated field is written with a value equal to its own
  # rendered form (single spaces between tokens, the atom's own name) so a
  # plain slice-equality assertion holds without needing to reverse the
  # tokenization. No fixture in this project uses entity references inside an
  # attribute value, so the "allowing for entity expansion" caveat in the
  # plan is a non-issue here.
  @source """
  <scxml initial="s1" name="root" datamodel="null" binding="late" version="1.0" xmlns="http://www.w3.org/2005/07/scxml">
      <state id="s1" initial="s1a">
          <state id="s1a">
              <onentry>
                  <raise event="go"/>
                  <log label="hi" expr="1 + 1"/>
              </onentry>
              <onexit>
                  <log label="bye"/>
              </onexit>
              <initial>
                  <transition target="s1a" event="e1 e2" cond="x &gt; 1" type="internal"/>
              </initial>
              <history id="h1" type="deep"/>
              <transition target="s1a" event="e3"/>
          </state>
      </state>
      <parallel id="p1"/>
      <final id="f1">
          <donedata>
              <content expr="'done'">payload</content>
          </donedata>
      </final>
  </scxml>
  """

  defp lower! do
    {:ok, root} = Parser.parse(@source)
    {:ok, document} = Lowering.lower(root, @source)
    document
  end

  # A node's own `location` slices back to text starting at its own start
  # tag - self-closing or not.
  defp assert_node_location(location, tag) do
    slice = Location.slice(location, @source)

    assert slice =~ ~r/\A<#{Regex.escape(tag)}[\s\/>]/,
           "#{tag}'s span does not start at its own start tag: #{inspect(slice)}"
  end

  # An `attribute_locations` entry slices back to exactly the value the
  # struct's own field carries (rendered as source text) - not the whole
  # `name="value"` span.
  defp assert_attribute_location(attribute_locations, key, expected) do
    location = Map.fetch!(attribute_locations, key)
    assert Location.slice(location, @source) == expected
  end

  # sabotage: `Attributes.put_location/4` stores `attribute.location` (the
  # whole `name="value"` span, quotes and attribute name included) instead
  # of `attribute.value_location` (the span inside the quotes alone) -> every
  # `assert_attribute_location/3` call below gains a `name="`/`"` wrapper
  # around the expected text, and the exact-equality assertions redden
  test "every node and attribute span in a full document tree slices back to its own text" do
    document = lower!()

    assert_node_location(document.location, "scxml")
    assert_attribute_location(document.attribute_locations, :initial, "s1")
    assert_attribute_location(document.attribute_locations, :name, "root")
    assert_attribute_location(document.attribute_locations, :datamodel, "null")
    assert_attribute_location(document.attribute_locations, :binding, "late")
    assert_attribute_location(document.attribute_locations, :version, "1.0")

    assert_attribute_location(
      document.attribute_locations,
      :xmlns,
      "http://www.w3.org/2005/07/scxml"
    )

    assert [%State{} = s1, %State{kind: :parallel} = p1, %State{kind: :final} = f1] =
             document.states

    assert_node_location(s1.location, "state")
    assert_attribute_location(s1.attribute_locations, :id, "s1")
    assert_attribute_location(s1.attribute_locations, :initial, "s1a")

    assert [%State{} = s1a] = s1.states
    assert_node_location(s1a.location, "state")
    assert_attribute_location(s1a.attribute_locations, :id, "s1a")

    assert [%Block{} = onentry] = s1a.onentry
    assert_node_location(onentry.location, "onentry")

    assert [%Raise{} = raise_node, %Log{} = log1] = onentry.content
    assert_node_location(raise_node.location, "raise")
    assert_attribute_location(raise_node.attribute_locations, :event, "go")

    assert_node_location(log1.location, "log")
    assert_attribute_location(log1.attribute_locations, :label, "hi")
    assert_attribute_location(log1.attribute_locations, :expr, "1 + 1")

    assert [%Block{} = onexit] = s1a.onexit
    assert_node_location(onexit.location, "onexit")
    assert [%Log{} = log2] = onexit.content
    assert_node_location(log2.location, "log")
    assert_attribute_location(log2.attribute_locations, :label, "bye")

    assert %Initial{} = initial = s1a.initial_element
    assert_node_location(initial.location, "initial")

    assert [%Transition{} = t1] = initial.transitions
    assert_node_location(t1.location, "transition")
    assert_attribute_location(t1.attribute_locations, :target, "s1a")
    assert_attribute_location(t1.attribute_locations, :event, "e1 e2")
    assert_attribute_location(t1.attribute_locations, :cond, "x &gt; 1")
    assert_attribute_location(t1.attribute_locations, :type, "internal")

    assert [%State{kind: :history} = history] = s1a.states
    assert_node_location(history.location, "history")
    assert_attribute_location(history.attribute_locations, :id, "h1")
    assert_attribute_location(history.attribute_locations, :type, "deep")

    assert [%Transition{} = t2] = s1a.transitions
    assert_node_location(t2.location, "transition")
    assert_attribute_location(t2.attribute_locations, :target, "s1a")
    assert_attribute_location(t2.attribute_locations, :event, "e3")

    assert_node_location(p1.location, "parallel")
    assert_attribute_location(p1.attribute_locations, :id, "p1")

    assert_node_location(f1.location, "final")
    assert_attribute_location(f1.attribute_locations, :id, "f1")

    assert %Donedata{content: %Content{} = content} = f1.donedata
    assert_node_location(content.location, "content")
    assert_attribute_location(content.attribute_locations, :expr, "'done'")
    assert content.text == "payload"
  end
end
