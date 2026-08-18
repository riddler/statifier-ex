defmodule Statifier.Parser.HandlerTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser.{DOM, Handler, Location, Markup, ParseError}

  defp init(source), do: Handler.init(source, Markup.scan(source))

  defp open_children(state), do: state.stack |> hd() |> Map.fetch!(:children)

  describe "the zip" do
    # sabotage: pop/3's matching clause stops binding `name` twice in the
    # head (`%Markup{kind: kind, name: _name}`), so the guard no longer
    # compares the queued record's name against the event's -> the wrong
    # record is popped and the desync goes unreported, reddening the
    # :location_desync match below
    test "a name mismatch between the queue and the event aborts with a desync" do
      source = "<b/>"

      assert {:stop, {:error, %ParseError{} = error}} =
               Handler.handle_event(:start_element, {"a", []}, init(source))

      assert error.reason == {:location_desync, "b", "a"}
      assert error.byte_offset == 0
      assert %Location{start_line: 1, start_column: 1} = error.location
    end

    # sabotage: pop/3's mismatch clause passes the two names to
    # ParseError.desync/3 the wrong way round -> the error blames the event
    # for the record's name, reddening the reason match below
    test "a mismatch reported by an end event names the record still queued" do
      source = "<a><b/></a>"
      state = init(source)

      assert {:ok, state} = Handler.handle_event(:start_element, {"a", []}, state)

      assert {:stop, {:error, %ParseError{reason: {:location_desync, "b", "a"}}}} =
               Handler.handle_event(:end_element, "a", state)
    end

    # sabotage: pop/3's empty-queue clause returns `{:ok, nil, []}` instead
    # of a desync -> the handler proceeds with no record and raises on
    # `record.attributes`, reddening this test
    test "an exhausted queue aborts rather than proceeding without a record" do
      assert {:stop, {:error, %ParseError{} = error}} =
               Handler.handle_event(:start_element, {"a", []}, Handler.init("", []))

      assert error.reason == {:location_desync, "", "a"}
      assert %Location{start_offset: 0, end_offset: 0} = error.location
    end
  end

  describe "text runs" do
    # sabotage: add_text/2's `[%DOM.Text{} = text | rest]` clause is deleted,
    # so every event starts a new node -> the CDATA arrives as a second text
    # node, reddening the single-node match below
    test "characters and cdata in one run coalesce into a single text node" do
      source = "<a>x<![CDATA[y]]></a>"

      state = init(source)
      assert {:ok, state} = Handler.handle_event(:start_element, {"a", []}, state)
      assert {:ok, state} = Handler.handle_event(:characters, "x", state)
      assert {:ok, state} = Handler.handle_event(:cdata, "y", state)

      assert [%DOM.Text{value: "xy", location: location}] = open_children(state)
      assert Location.slice(location, source) == "x<![CDATA[y]]>"
    end

    # sabotage: the `:cdata` clause of handle_event/3 delegates to
    # `{:ok, state}` instead of `add_text/2` -> the CDATA text is dropped,
    # reddening the value assertion
    test "a cdata event on its own produces a text node" do
      source = "<a><![CDATA[y]]></a>"

      state = init(source)
      assert {:ok, state} = Handler.handle_event(:start_element, {"a", []}, state)
      assert {:ok, state} = Handler.handle_event(:cdata, "y", state)

      assert [%DOM.Text{value: "y"}] = open_children(state)
    end

    # sabotage: text_span/1's empty-queue clause spans `cursor` to `cursor`
    # instead of to the end of the source -> the span is zero-width and
    # slices to "", reddening the slice assertion
    test "a run with no markup left ahead of it spans to the end of the source" do
      source = "trailing"

      assert {:ok, state} =
               Handler.handle_event(:characters, source, Handler.init(source, []))

      assert [%DOM.Text{value: "trailing", location: location}] = open_children(state)
      assert Location.slice(location, source) == "trailing"
      assert %Location{start_line: 1, start_column: 1, end_line: 1, end_column: 9} = location
    end
  end

  describe "document boundaries" do
    # sabotage: the `:end_document` clause returns `{:ok, state}` instead of
    # `{:ok, root}` -> the handler state leaks out where the root element
    # should be, reddening the %DOM.Element{} match below
    test "end_document yields the single root the document frame collected" do
      source = "<a/>"
      state = init(source)

      assert {:ok, state} = Handler.handle_event(:start_document, [], state)
      assert {:ok, state} = Handler.handle_event(:start_element, {"a", []}, state)
      assert {:ok, state} = Handler.handle_event(:end_element, "a", state)

      assert {:ok, %DOM.Element{name: "a"}} = Handler.handle_event(:end_document, {}, state)
    end
  end
end
