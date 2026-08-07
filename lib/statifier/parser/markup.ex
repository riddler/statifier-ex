defmodule Statifier.Parser.Markup do
  @moduledoc """
  A total, left-to-right scan of an XML source binary that produces the
  positions Saxy does not.

  Saxy 1.6.1 passes handlers no position data of any kind and has no option
  to enable it (`deps/saxy/lib/saxy/handler.ex`), so positions are produced
  by this independent scan and zipped against the SAX event stream by index
  in `Statifier.Parser.Handler` - the Nth start-tag record this scanner
  finds is the Nth `:start_element` Saxy emits. See
  `docs/plans/260807-st-l5k.3-sax-dom-source-locations.md`, Decision 1.

  The scan only ever answers "is this a markup construct, and where does it
  start and end". It classifies each `<` by the bytes that follow it -
  `<!--` comment (skipped to `-->`), `<![CDATA[` (skipped to `]]>`),
  `<!DOCTYPE` (skipped to `>`, honoring an internal `[...]` subset), `<?` PI
  or the XML declaration (skipped to `?>`), `</` an end tag, anything else a
  start tag - and never interprets content, expands entities, or validates.
  A self-closing `<b/>` emits **two** records, a `:start` and an `:end` with
  identical spans, so the record stream stays 1:1 with Saxy's element events
  by construction.

  It is a **total function**: it never raises, on any binary, including
  malformed or truncated XML. On a malformed document, Saxy's own error is
  what surfaces to `Statifier.Parser.parse/1`; this scanner's only
  obligation on such input is to return *a* list without crashing, since a
  well-formed document is Saxy's job to reject, not this scanner's.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:kind, :name, :location]
  defstruct kind: nil, name: nil, location: nil, attributes: []

  @type attribute :: %{
          name: binary(),
          location: Location.t(),
          value_location: Location.t()
        }

  @type t :: %__MODULE__{
          kind: :start | :end,
          name: binary(),
          location: Location.t(),
          attributes: [attribute()]
        }

  @whitespace [" ", "\t", "\n", "\r"]
  @tag_stop_chars @whitespace ++ ["/", ">"]
  @attr_stop_chars @tag_stop_chars ++ ["="]

  @doc """
  Scans `source` into an ordered list of start/end tag records.

  Total over any binary - see the moduledoc. Comments, CDATA sections,
  DOCTYPE declarations, and processing instructions (including the XML
  declaration) are skipped without producing a record; only start and end
  tags do.
  """
  @spec scan(source :: binary()) :: [t()]
  def scan(source) when is_binary(source) do
    walk(source, {0, 1, 1}, [])
  end

  defp walk(<<>>, _pos, acc), do: Enum.reverse(acc)

  defp walk(<<"<", _rest::binary>> = bin, pos, acc) do
    {records, rest, rest_pos} = classify_markup(bin, pos)
    walk(rest, rest_pos, Enum.reverse(records) ++ acc)
  end

  defp walk(bin, pos, acc) do
    case String.next_codepoint(bin) do
      nil -> Enum.reverse(acc)
      {codepoint, rest} -> walk(rest, advance(pos, codepoint), acc)
    end
  end

  defp classify_markup(bin, pos) do
    cond do
      literal?(bin, "<!--") -> skip("<!--", bin, pos, "-->")
      literal?(bin, "<![CDATA[") -> skip("<![CDATA[", bin, pos, "]]>")
      literal?(bin, "<!DOCTYPE") -> skip_doctype_markup(bin, pos)
      literal?(bin, "<?") -> skip("<?", bin, pos, "?>")
      literal?(bin, "</") -> scan_end_tag(bin, pos)
      true -> scan_start_tag(bin, pos)
    end
  end

  defp skip_doctype_markup(bin, pos) do
    {rest, rest_pos} = skip_doctype(after_literal(bin, "<!DOCTYPE"), advance_ascii(pos, 9))
    {[], rest, rest_pos}
  end

  defp skip(prefix, bin, pos, delim) do
    prefix_size = byte_size(prefix)

    {rest, rest_pos} =
      consume_until(after_literal(bin, prefix), advance_ascii(pos, prefix_size), delim)

    {[], rest, rest_pos}
  end

  defp consume_until(<<>>, pos, _delim), do: {<<>>, pos}

  defp consume_until(bin, pos, delim) do
    if literal?(bin, delim) do
      {after_literal(bin, delim), advance_ascii(pos, byte_size(delim))}
    else
      {codepoint, rest} = String.next_codepoint(bin)
      consume_until(rest, advance(pos, codepoint), delim)
    end
  end

  # Tracks `[...]` bracket depth so a `>` that closes a markup declaration
  # inside the internal subset (e.g. `<!ELEMENT a EMPTY>`) does not end the
  # DOCTYPE itself; only a `>` at depth 0 does.
  defp skip_doctype(bin, pos), do: skip_doctype(bin, pos, 0)

  defp skip_doctype(<<>>, pos, _depth), do: {<<>>, pos}

  defp skip_doctype(bin, pos, depth) do
    case String.next_codepoint(bin) do
      {"[", rest} -> skip_doctype(rest, advance(pos, "["), depth + 1)
      {"]", rest} -> skip_doctype(rest, advance(pos, "]"), max(depth - 1, 0))
      {">", rest} when depth == 0 -> {rest, advance(pos, ">")}
      {codepoint, rest} -> skip_doctype(rest, advance(pos, codepoint), depth)
    end
  end

  defp scan_end_tag(bin, pos) do
    name_start = advance_ascii(pos, 2)
    {name, _rest, _name_pos} = read_name(after_literal(bin, "</"), name_start, @tag_stop_chars)
    {rest, end_pos} = consume_until(after_literal(bin, "</"), name_start, ">")

    {[%__MODULE__{kind: :end, name: name, location: span(pos, end_pos)}], rest, end_pos}
  end

  defp scan_start_tag(bin, pos) do
    name_start = advance_ascii(pos, 1)
    {name, rest, name_end} = read_name(after_literal(bin, "<"), name_start, @tag_stop_chars)
    {attributes, self_closing?, rest, tag_end} = scan_attributes(rest, name_end, [])

    start_record = %__MODULE__{
      kind: :start,
      name: name,
      location: span(pos, tag_end),
      attributes: attributes
    }

    if self_closing? do
      end_record = %__MODULE__{kind: :end, name: name, location: span(pos, tag_end)}
      {[start_record, end_record], rest, tag_end}
    else
      {[start_record], rest, tag_end}
    end
  end

  defp scan_attributes(bin, pos, acc) do
    {bin, pos} = skip_whitespace(bin, pos)

    cond do
      literal?(bin, "/>") ->
        {Enum.reverse(acc), true, after_literal(bin, "/>"), advance_ascii(pos, 2)}

      literal?(bin, ">") ->
        {Enum.reverse(acc), false, after_literal(bin, ">"), advance_ascii(pos, 1)}

      bin == <<>> ->
        {Enum.reverse(acc), false, <<>>, pos}

      true ->
        parse_attribute(bin, pos, acc)
    end
  end

  defp parse_attribute(bin, pos, acc) do
    attr_start = pos
    {name, bin, pos} = read_name(bin, pos, @attr_stop_chars)

    if name == "" do
      # No valid attribute-name character here (e.g. a stray "="): force
      # progress by consuming one codepoint so a malformed tag still
      # terminates the scan instead of looping.
      case String.next_codepoint(bin) do
        nil -> scan_attributes(<<>>, pos, acc)
        {codepoint, rest} -> scan_attributes(rest, advance(pos, codepoint), acc)
      end
    else
      parse_attribute_value(bin, pos, attr_start, name, acc)
    end
  end

  defp parse_attribute_value(bin, pos, attr_start, name, acc) do
    {bin, pos} = skip_whitespace(bin, pos)

    case bin do
      <<"=", rest::binary>> ->
        {bin, pos} = skip_whitespace(rest, advance_ascii(pos, 1))
        parse_quoted_value(bin, pos, attr_start, name, acc)

      _no_equals ->
        # No `=` follows the name (a valueless or otherwise malformed
        # attribute token): drop it and keep scanning the tag.
        scan_attributes(bin, pos, acc)
    end
  end

  defp parse_quoted_value(<<quote, rest::binary>>, pos, attr_start, name, acc)
       when quote in [?', ?"] do
    quote_char = <<quote>>
    value_start = advance_ascii(pos, 1)
    {value_end, closing_pos, rest} = scan_quoted_value(rest, value_start, quote_char)

    attribute = %{
      name: name,
      location: span(attr_start, closing_pos),
      value_location: span(value_start, value_end)
    }

    scan_attributes(rest, closing_pos, [attribute | acc])
  end

  defp parse_quoted_value(bin, pos, _attr_start, _name, acc) do
    # No opening quote (an unquoted value, or nothing at all): drop the
    # would-be attribute and resynchronize at the next boundary.
    {rest, rest_pos} = skip_to_tag_boundary(bin, pos)
    scan_attributes(rest, rest_pos, acc)
  end

  defp scan_quoted_value(bin, pos, quote_char) do
    cond do
      literal?(bin, quote_char) ->
        {pos, advance_ascii(pos, 1), after_literal(bin, quote_char)}

      bin == <<>> ->
        {pos, pos, <<>>}

      true ->
        {codepoint, rest} = String.next_codepoint(bin)
        scan_quoted_value(rest, advance(pos, codepoint), quote_char)
    end
  end

  defp skip_to_tag_boundary(<<>>, pos), do: {<<>>, pos}

  defp skip_to_tag_boundary(bin, pos) do
    if literal?(bin, ">") do
      {bin, pos}
    else
      case String.next_codepoint(bin) do
        {codepoint, _rest} when codepoint in @whitespace -> {bin, pos}
        {codepoint, rest} -> skip_to_tag_boundary(rest, advance(pos, codepoint))
      end
    end
  end

  defp skip_whitespace(bin, pos) do
    case String.next_codepoint(bin) do
      {codepoint, rest} when codepoint in @whitespace ->
        skip_whitespace(rest, advance(pos, codepoint))

      _not_whitespace ->
        {bin, pos}
    end
  end

  defp read_name(bin, pos, stop_chars), do: read_name(bin, pos, stop_chars, [])

  defp read_name(bin, pos, stop_chars, acc) do
    case String.next_codepoint(bin) do
      nil ->
        {IO.iodata_to_binary(Enum.reverse(acc)), bin, pos}

      {codepoint, rest} ->
        if codepoint in stop_chars do
          {IO.iodata_to_binary(Enum.reverse(acc)), bin, pos}
        else
          read_name(rest, advance(pos, codepoint), stop_chars, [codepoint | acc])
        end
    end
  end

  defp literal?(bin, literal) do
    byte_size(bin) >= byte_size(literal) and binary_part(bin, 0, byte_size(literal)) == literal
  end

  defp after_literal(bin, literal) do
    size = byte_size(literal)
    binary_part(bin, size, byte_size(bin) - size)
  end

  # Advances a {offset, line, column} cursor past `codepoint`. Columns count
  # codepoints, not bytes, so non-ASCII text still reports the right column.
  defp advance({offset, line, _column}, "\n"), do: {offset + 1, line + 1, 1}

  defp advance({offset, line, column}, codepoint) do
    {offset + byte_size(codepoint), line, column + 1}
  end

  # Advances a cursor past `count` bytes of a known-ASCII, newline-free
  # delimiter (tag punctuation, quotes) - byte count and codepoint count
  # coincide, so this skips the per-codepoint walk for the common case.
  defp advance_ascii({offset, line, column}, count), do: {offset + count, line, column + count}

  defp span({start_offset, start_line, start_column}, {end_offset, end_line, end_column}) do
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
