defmodule Statifier.Parser.Location do
  @moduledoc """
  A source span: 1-based line/column (columns counted in Unicode codepoints),
  0-based byte offsets, exclusive end - the shape ADR-0014 fixed for
  expression spans, used here for XML nodes so the two compose.

  Keeping both line/column and byte offsets is what lets an ADR-0014
  expression span be resolved into an absolute document span: the line/column
  half is the coordinate system a predicator span speaks
  (`t:Predicator.Types.span/0` is a pair of 1-based `{line, column}`
  positions - there is no offset in it, so no arithmetic on `start_offset`
  stands in for the composition), and the offset half is what makes the
  result sliceable back out of the source. `resolve_span/4` does the
  composition, accounting for entity references in the raw text.
  """

  @enforce_keys [
    :start_line,
    :start_column,
    :start_offset,
    :end_line,
    :end_column,
    :end_offset
  ]
  defstruct [
    :start_line,
    :start_column,
    :start_offset,
    :end_line,
    :end_column,
    :end_offset
  ]

  @type t :: %__MODULE__{
          start_line: pos_integer(),
          start_column: pos_integer(),
          start_offset: non_neg_integer(),
          end_line: pos_integer(),
          end_column: pos_integer(),
          end_offset: non_neg_integer()
        }

  @doc """
  A zero-width span at `offset`, counting newlines and codepoints over
  `binary_part(source, 0, offset)`.

  Used to convert a `Saxy.ParseError` byte offset into a location; `offset`
  must not exceed `byte_size(source)`.
  """
  @spec at_offset(source :: binary(), offset :: non_neg_integer()) :: t()
  def at_offset(source, offset) when is_binary(source) and is_integer(offset) and offset >= 0 do
    {line, column} = line_and_column(binary_part(source, 0, offset))

    %__MODULE__{
      start_line: line,
      start_column: column,
      start_offset: offset,
      end_line: line,
      end_column: column,
      end_offset: offset
    }
  end

  @doc """
  The raw source bytes `location` spans, sliced out of `source`.

  The primitive the location-accuracy sweep is built on: slicing a node's
  span back out of the source and asserting it starts with the expected text
  catches an off-by-one anywhere in the producer, without hardcoding a line
  number.
  """
  @spec slice(location :: t(), source :: binary()) :: binary()
  def slice(%__MODULE__{start_offset: start_offset, end_offset: end_offset}, source)
      when is_binary(source) do
    binary_part(source, start_offset, end_offset - start_offset)
  end

  @doc """
  The absolute document span of the subexpression `span` covers.

  `value_location` is the raw-source span of an attribute's value (the text
  inside the quotes); `value` is the entity-expanded string that was handed to
  predicator - `Machine.expr()`'s `{:compiled, _, source}` third element, or
  `Statifier.Evaluator.Error`'s `:source` - and `span` is a predicator span
  over `value`, 1-based line/column with an exclusive end
  (`t:Predicator.Types.span/0`). The returned location's end is exclusive too.

  `value` is required rather than reconstructed: predicator counted columns in
  that exact string, and a reference in the raw source (`&lt;`, `&#10;`) makes
  raw and expanded coordinates diverge. Walking the two together is what keeps
  the result exact; re-deriving the expansion here would only model it. The raw
  text is *not* required, because `slice/2` recovers it from `source`.

  Requires `value`'s position `{1, 1}` to be `value_location`'s start - true of
  every attribute-sourced expression, since
  `Statifier.Compiler.Expressions.compile/3` does not trim. A caller that
  trimmed before compiling must adjust the anchor itself.

  Degrades rather than raising: a position past the end of `value` clamps to
  `value_location`'s end, and a `value` that does not describe the same text as
  the raw slice returns `value_location` whole - underlining the entire
  attribute value instead of a subexpression.

  A `nil` `value_location` or a `nil` span has nothing to resolve; the caller
  falls back to the owning node's own `location` rather than calling this.
  """
  @spec resolve_span(
          value_location :: t(),
          span :: Predicator.Types.span(),
          value :: binary(),
          source :: binary()
        ) :: t()
  def resolve_span(
        %__MODULE__{} = value_location,
        {{_start_line, _start_column}, {_end_line, _end_column}} = span,
        value,
        source
      )
      when is_binary(value) and is_binary(source) do
    raw = slice(value_location, source)

    raw_cursor = {
      value_location.start_offset,
      value_location.start_line,
      value_location.start_column
    }

    {start_target, end_target} = span

    case walk_spans(raw, value, raw_cursor, {1, 1}, start_target, end_target, %{
           start: nil,
           end: nil
         }) do
      :desync ->
        value_location

      {:ok, start_pos, end_pos} ->
        span_location(start_pos, end_pos)
    end
  end

  defp span_location({start_offset, start_line, start_column}, {end_offset, end_line, end_column}) do
    %__MODULE__{
      start_line: start_line,
      start_column: start_column,
      start_offset: start_offset,
      end_line: end_line,
      end_column: end_column,
      end_offset: end_offset
    }
  end

  # A single left-to-right lockstep walk over the raw-source slice and the
  # entity-expanded value, carrying a raw cursor (offset/line/column) and an
  # expanded cursor (line/column). Before consuming each unit, both targets
  # are checked against the current expanded position, and the raw cursor is
  # captured the first time each target is reached or passed - which is what
  # preserves the exclusive-end convention, since the end target's "first
  # position not covered" resolves by the identical rule as the start.
  defp walk_spans(raw, value, raw_cursor, expanded_pos, start_target, end_target, captured) do
    captured =
      captured
      |> maybe_capture(:start, start_target, expanded_pos, raw_cursor)
      |> maybe_capture(:end, end_target, expanded_pos, raw_cursor)

    if raw == "" and value == "" do
      {:ok, captured.start || raw_cursor, captured.end || raw_cursor}
    else
      case next_unit(raw, value) do
        :desync ->
          :desync

        {:ok, raw_token, expanded_codepoint, raw_rest, value_rest} ->
          walk_spans(
            raw_rest,
            value_rest,
            raw_advance_string(raw_cursor, raw_token),
            expanded_advance(expanded_pos, expanded_codepoint),
            start_target,
            end_target,
            captured
          )
      end
    end
  end

  defp maybe_capture(captured, key, target, expanded_pos, raw_cursor) do
    if is_nil(Map.fetch!(captured, key)) and expanded_pos >= target do
      Map.put(captured, key, raw_cursor)
    else
      captured
    end
  end

  # The four-case unit rule: a decoded reference token (case 1), identical
  # leading codepoints (case 2), a TAB/LF/CR-versus-space normalization pair
  # (case 3), or desync (case 4). Every decode is validated against `value`
  # before it is believed (`String.starts_with?/2` below), so a malformed or
  # unexpected reference can only ever fall through to case 2/3/4, never
  # produce a wrong answer.
  defp next_unit(raw, value) do
    case match_reference(raw) do
      {token, decoded} ->
        if String.starts_with?(value, decoded) do
          raw_rest = binary_part(raw, byte_size(token), byte_size(raw) - byte_size(token))

          value_rest =
            binary_part(value, byte_size(decoded), byte_size(value) - byte_size(decoded))

          {:ok, token, decoded, raw_rest, value_rest}
        else
          next_unit_plain(raw, value)
        end

      nil ->
        next_unit_plain(raw, value)
    end
  end

  defp next_unit_plain(raw, value) do
    with {raw_cp, raw_rest} <- String.next_codepoint(raw),
         {value_cp, value_rest} <- String.next_codepoint(value) do
      cond do
        raw_cp == value_cp ->
          {:ok, raw_cp, value_cp, raw_rest, value_rest}

        raw_cp in ["\t", "\n", "\r"] and value_cp == " " ->
          {:ok, raw_cp, value_cp, raw_rest, value_rest}

        true ->
          :desync
      end
    else
      _empty -> :desync
    end
  end

  # A single capture group around the whole `lt|gt|amp|quot|apos|#N|#xN` body,
  # rather than one alternative per reference kind: Elixir's `Regex.run/2`
  # drops trailing capture groups that did not participate in the match, so
  # `[full, named, hex, dec]` would silently fail to match whenever anything
  # but the first alternative fired, always falling back to `nil`.
  @reference_regex ~r/\A&(lt|gt|amp|quot|apos|#x[0-9A-Fa-f]+|#[0-9]+);/

  defp match_reference(raw) do
    with [full, body] <- Regex.run(@reference_regex, raw),
         decoded when not is_nil(decoded) <- decode_reference(body) do
      {full, decoded}
    else
      _no_reference -> nil
    end
  end

  defp decode_reference("#x" <> hex), do: codepoint_string(String.to_integer(hex, 16))
  defp decode_reference("#" <> dec), do: codepoint_string(String.to_integer(dec, 10))
  defp decode_reference(named), do: named_codepoint(named)

  defp named_codepoint("lt"), do: "<"
  defp named_codepoint("gt"), do: ">"
  defp named_codepoint("amp"), do: "&"
  defp named_codepoint("quot"), do: "\""
  defp named_codepoint("apos"), do: "'"

  # XML 1.0 4.1 excludes surrogate code points from a character reference; an
  # out-of-range value is a malformed reference, not a codepoint to trust, so
  # it degrades to `nil` (falls through to the plain/normalize/desync cases)
  # rather than raising out of `List.to_string/1` or `<<cp::utf8>>`.
  defp codepoint_string(codepoint)
       when codepoint in 0..0xD7FF or codepoint in 0xE000..0x10FFFF do
    <<codepoint::utf8>>
  end

  defp codepoint_string(_codepoint), do: nil

  # Advances a {offset, line, column} raw cursor past `str`, one codepoint at
  # a time - `str` is either a single plain codepoint or a whole reference
  # token (`&lt;`, `&#10;`), neither of which ever contains an actual newline
  # byte, so `\n` is only ever reached via the plain/normalize cases.
  defp raw_advance_string(cursor, str) do
    str
    |> String.codepoints()
    |> Enum.reduce(cursor, &raw_advance_codepoint(&2, &1))
  end

  defp raw_advance_codepoint({offset, line, _column}, "\n"), do: {offset + 1, line + 1, 1}

  defp raw_advance_codepoint({offset, line, column}, codepoint),
    do: {offset + byte_size(codepoint), line, column + 1}

  # Advances the expanded {line, column} cursor past one expanded codepoint.
  # `\r` holds the cursor still rather than advancing it, mirroring
  # predicator's lexer (`deps/predicator/lib/predicator/lexer.ex:225-226`,
  # `?\r -> tokenize_chars(rest, line, col, tokens)`), since that is the
  # coordinate system a predicator span is expressed in.
  defp expanded_advance({line, _column}, "\n"), do: {line + 1, 1}
  defp expanded_advance({line, column}, "\r"), do: {line, column}
  defp expanded_advance({line, column}, _codepoint), do: {line, column + 1}

  defp line_and_column(prefix) do
    lines = String.split(prefix, "\n")
    line = length(lines)
    column = (lines |> List.last() |> String.length()) + 1

    {line, column}
  end
end
