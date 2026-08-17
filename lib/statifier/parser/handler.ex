defmodule Statifier.Parser.Handler do
  @moduledoc """
  The `Saxy.Handler` that builds a `Statifier.Parser.DOM` tree, attaching the
  positions Saxy does not supply.

  Six clauses, and not one of them mentions an element name. v1's handler
  lowered elements into typed structs as it went, which needed a clause per
  (element type x parent context) pair - 73 of them in one module
  (`../statifier/lib/statifier/parser/scxml/state_stack.ex`). Building a
  generic node instead makes `:end_element` a single clause: append a child
  to the open frame, whatever either of them is called.

  ## The zip

  Saxy gives semantics and no positions; `Statifier.Parser.Markup` gives
  positions and no semantics. Both produce element boundaries in document
  order, and that is the join key - the Nth start-tag record the scanner
  found is the Nth `:start_element` Saxy emits - so this handler carries the
  scanner's records as a queue and pops exactly one per element event.

  The two passes disagreeing is the mechanism's one real risk, so it is
  checked rather than assumed: every popped record's name is compared against
  the name in the Saxy event and a mismatch aborts with
  `{:location_desync, expected, got}` instead of attaching a wrong location.
  Because Saxy does no namespace processing and no expansion touches names,
  the two spellings are byte-identical whenever the scan is in sync.

  Every pop advances `cursor` to the popped record's end, which is what makes
  text spans computable: a run of character data covers everything between
  the cursor and the start of the next queued record, raw source included.

  ## Attribute values

  `build_attributes/3` normalizes each attribute's value per XML 1.0 3.3.3
  (ADR-0043), walking the raw slice (`Location.slice(value_location, source)`)
  against Saxy's expanded value with `Location.normalize_attribute_value/3` -
  Saxy's value alone cannot tell a literal newline from an expanded `&#10;`,
  so the raw text is what disambiguates. When the scanner has no record for an
  attribute, or the record's `value_location` is `nil`, there is no raw slice
  to walk and Saxy's value stands unnormalized.

  ## Character data

  `add_text/2` folds each text run's `value` per XML 1.0 2.11 (ADR-0045),
  walking the run's raw span (`text_span/1`) against an *unfolded*
  accumulation of Saxy's characters with `Location.normalize_character_data/3`.
  The accumulation, not `value` itself, is what gets re-walked on every event
  of a coalescing run: `walk_units/3`'s raw-versus-expanded pairing requires
  both sides to empty together, and a raw `\\r` no longer pairs against an
  already-folded `\\n` the way it pairs against Saxy's still-unfolded `\\r\\n`.
  State carries this accumulation in a `text` field, reset implicitly by the
  coalescing check already in `add_text/2` - a fresh run starts from `""`
  because its frame's head child is not a `DOM.Text`. When the raw slice and
  the accumulation desync, `normalize_character_data/3` degrades to the
  unfolded value, the same posture attribute normalization takes.
  """

  @behaviour Saxy.Handler

  alias Statifier.Parser.DOM
  alias Statifier.Parser.Location
  alias Statifier.Parser.Markup
  alias Statifier.Parser.ParseError

  @type cursor :: {offset :: non_neg_integer(), line :: pos_integer(), column :: pos_integer()}

  @type frame :: %{
          record: Markup.t() | nil,
          attributes: [DOM.Attribute.t()],
          children: [DOM.Element.child()]
        }

  @type t :: %{
          source: binary(),
          markup: [Markup.t()],
          cursor: cursor(),
          stack: [frame()],
          text: binary()
        }

  @doc """
  The initial handler state for `source` and its scanned markup records.

  The stack starts with one frame standing in for the document itself, so
  `:end_element` never has to special-case the root: the root element is
  appended to that frame like any other child, and `:end_document` reads it
  back out.

  `text` starts empty; it is the unfolded accumulation `add_text/2` grows for
  whichever run is currently open (see the moduledoc's "Character data"
  section).
  """
  @spec init(source :: binary(), markup :: [Markup.t()]) :: t()
  def init(source, markup) when is_binary(source) and is_list(markup) do
    %{
      source: source,
      markup: markup,
      cursor: {0, 1, 1},
      stack: [%{record: nil, attributes: [], children: []}],
      text: ""
    }
  end

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  # Well-formed XML has exactly one root, and Saxy has already rejected
  # anything else by the time this fires, so the document frame holds
  # exactly one child.
  def handle_event(:end_document, _data, %{stack: [%{children: [root]}]}), do: {:ok, root}

  def handle_event(:start_element, {name, attributes}, state) do
    with {:ok, record, markup} <- pop(state, :start, name) do
      frame = %{
        record: record,
        attributes: build_attributes(state, attributes, record.attributes),
        children: []
      }

      {:ok, %{state | markup: markup, cursor: cursor_after(record), stack: [frame | state.stack]}}
    end
  end

  def handle_event(:end_element, name, state) do
    with {:ok, record, markup} <- pop(state, :end, name) do
      [frame, parent | ancestors] = state.stack

      element = %DOM.Element{
        name: name,
        attributes: frame.attributes,
        children: Enum.reverse(frame.children),
        location: span(frame.record.location, record.location)
      }

      parent = %{parent | children: [element | parent.children]}

      {:ok, %{state | markup: markup, cursor: cursor_after(record), stack: [parent | ancestors]}}
    end
  end

  def handle_event(:characters, characters, state), do: {:ok, add_text(state, characters)}

  def handle_event(:cdata, characters, state), do: {:ok, add_text(state, characters)}

  # The zip site: one record per element event, name-guarded. `kind` and
  # `name` repeat in the head, so this clause matches only when the queued
  # record is the one the event says it should be.
  defp pop(%{markup: [%Markup{kind: kind, name: name} = record | rest]}, kind, name) do
    {:ok, record, rest}
  end

  defp pop(%{markup: [%Markup{name: expected, location: location} | _rest]}, _kind, name) do
    {:stop, {:error, ParseError.desync(expected, name, location)}}
  end

  defp pop(%{markup: [], cursor: cursor}, _kind, name) do
    {:stop, {:error, ParseError.desync("", name, span_between(cursor, cursor))}}
  end

  defp add_text(state, characters) do
    [frame | ancestors] = state.stack
    location = text_span(state)

    {unfolded, children} =
      case frame.children do
        [%DOM.Text{} = text | rest] ->
          unfolded = state.text <> characters
          folded = folded_value(state, location, unfolded)
          {unfolded, [%DOM.Text{text | value: folded, location: location} | rest]}

        children ->
          folded = folded_value(state, location, characters)
          {characters, [%DOM.Text{value: folded, location: location} | children]}
      end

    %{state | text: unfolded, stack: [%{frame | children: children} | ancestors]}
  end

  # `unfolded` is Saxy's accumulation for the run so far, never `value` -
  # see the moduledoc's "Character data" section for why re-walking an
  # already-folded value against the raw slice would desync.
  defp folded_value(state, location, unfolded),
    do: Location.normalize_character_data(location, unfolded, state.source)

  # A text run ends where the next markup construct begins. Recomputing this
  # for every event of a split run is deliberate: the cursor has not moved,
  # so each event widens `value` while the span keeps covering the whole raw
  # run.
  defp text_span(%{markup: [%Markup{location: location} | _rest], cursor: cursor}) do
    span_between(cursor, {location.start_offset, location.start_line, location.start_column})
  end

  defp text_span(%{markup: [], cursor: cursor, source: source}) do
    eof = Location.at_offset(source, byte_size(source))

    span_between(cursor, {eof.start_offset, eof.start_line, eof.start_column})
  end

  # Saxy reports names and expanded values; the scanner reports where each
  # attribute sat. They are the same attributes in the same order, so the
  # join is by index.
  defp build_attributes(state, event_attributes, scanned_attributes) do
    event_attributes
    |> Enum.with_index()
    |> Enum.map(fn {{name, value}, index} ->
      scanned = Enum.at(scanned_attributes, index)

      %DOM.Attribute{
        name: name,
        value: normalized_value(state, scanned, value),
        location: scanned && scanned.location,
        value_location: scanned && scanned.value_location
      }
    end)
  end

  # No scanner record, or one without a value span, means no raw text to
  # disambiguate a literal from a reference - so Saxy's value stands
  # unnormalized rather than being guessed at (ADR-0043).
  defp normalized_value(_state, nil, value), do: value
  defp normalized_value(_state, %{value_location: nil}, value), do: value

  defp normalized_value(state, %{value_location: value_location}, value),
    do: Location.normalize_attribute_value(value_location, value, state.source)

  defp cursor_after(%Markup{location: location}) do
    {location.end_offset, location.end_line, location.end_column}
  end

  defp span(%Location{} = start_location, %Location{} = end_location) do
    %Location{
      start_line: start_location.start_line,
      start_column: start_location.start_column,
      start_offset: start_location.start_offset,
      end_line: end_location.end_line,
      end_column: end_location.end_column,
      end_offset: end_location.end_offset
    }
  end

  defp span_between({start_offset, start_line, start_column}, {end_offset, end_line, end_column}) do
    %Location{
      start_line: start_line,
      start_column: start_column,
      start_offset: start_offset,
      end_line: end_line,
      end_column: end_column,
      end_offset: end_offset
    }
  end
end
