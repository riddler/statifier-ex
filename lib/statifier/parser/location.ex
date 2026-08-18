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

  `value` is `Attribute.value`, which by the time this is called is already
  XML 1.0 3.3.3-normalized (`normalize_attribute_value/3`, ADR-0043): a
  literal TAB/LF/CR in the raw slice appears here as a space, a raw CRLF pair
  as one space, and a character reference as its decoded character. This walk
  pairs both against the raw slice exactly as the normalization walk does,
  which is what keeps a normalized span resolving to the right raw text.
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

  @doc """
  `value` with XML 1.0 3.3.3 attribute-value normalization applied.

  `value_location` is the raw-source span of the attribute's value and `value`
  is Saxy's entity-expanded string. Saxy applies neither 3.3.3 nor 2.11, so a
  literal TAB/LF/CR survives into `value` verbatim - indistinguishable, in that
  string alone, from an expanded `&#9;`/`&#10;`/`&#13;`, which 3.3.3 requires be
  kept as-is. The raw slice is what draws the distinction, so the two are walked
  in lockstep by the same unit rule `resolve_span/4` uses.

  Literal `#x20`/`#x9`/`#xA`/`#xD` each append one space; a literal `\\r\\n`
  pair appends one space between them (2.11 folds before 3.3.3 maps); a
  reference appends its decoded character verbatim. CDATA treatment only -
  statifier reads no attribute declarations, so nothing is trimmed or
  collapsed (ADR-0043).

  Degrades rather than raising: if the raw slice and `value` desync, `value` is
  returned unnormalized.
  """
  @spec normalize_attribute_value(value_location :: t(), value :: binary(), source :: binary()) ::
          binary()
  def normalize_attribute_value(%__MODULE__{} = value_location, value, source)
      when is_binary(value) and is_binary(source) do
    case walk_units(slice(value_location, source), value, []) do
      :desync -> value
      {:ok, units} -> units |> Enum.reverse() |> normalize_units([])
    end
  end

  @doc """
  `value` with XML 1.0 2.11 line-break folding applied, guided by the raw
  source.

  `location` is the raw-source span of a character-data run (a text node's
  whole run, coalesced across split events exactly as `Handler.add_text/2`
  recomputes it) and `value` is Saxy's entity-expanded string for that run.
  Saxy applies no 2.11 (same finding as `normalize_attribute_value/3`), so a
  literal CRLF or lone CR survives into `value` verbatim - indistinguishable,
  in that string alone, from a `\\r` decoded from `&#xD;`, which 2.11 must
  never fold. XML 1.0 2.11 (End-of-Line Handling), quoted from
  https://www.w3.org/TR/xml/#sec-line-ends as recorded in ADR-0045 (no local
  cache holds the XML 1.0 REC - `mise run spec:fetch` only populates the
  SCXML REC and its Appendix D extract - so this quote is carried from the
  ADR's own fetch rather than re-fetched here):

  > To simplify the tasks of applications, the XML processor MUST behave as
  > if it normalized all line breaks in external parsed entities (including
  > the document entity) on input, before parsing, by translating both the
  > two-character sequence #xD #xA and any #xD that is not followed by #xA
  > to a single #xA character.

  Unlike `normalize_attribute_value/3`, this applies no 3.3.3
  whitespace-to-space mapping - that rule is attribute-specific, so a TAB and
  a folded newline are both kept in character data (ADR-0045 item 1).

  The raw run can straddle constructs the scanner elides from `value`
  entirely - `<!--`...`-->`, `<?`...`?>`, and the `<![CDATA[`/`]]>` delimiters
  (`Markup.scan/1`, ADR-0045 item 2) - which contribute nothing to the
  expanded side and must not be mistaken for character data. A CDATA
  section's *interior* is not one of those: it is real character data, walked
  verbatim with no reference decoding (`&amp;` inside a CDATA section is five
  literal characters on both sides, never `"&"`), so a literal CR inside it
  folds exactly as one outside does.

  Degrades rather than raising: if the raw slice and `value` desync, `value`
  is returned unfolded, the same posture `normalize_attribute_value/3` and
  `resolve_span/4` take.
  """
  @spec normalize_character_data(location :: t(), value :: binary(), source :: binary()) ::
          binary()
  def normalize_character_data(%__MODULE__{} = location, value, source)
      when is_binary(value) and is_binary(source) do
    case walk_units(slice(location, source), value, :text, [], &next_text_unit/3) do
      :desync -> value
      {:ok, units} -> units |> Enum.reverse() |> fold_units([])
    end
  end

  # Same recursion shape as `walk_spans/7`, but carrying no cursors: it
  # accumulates `{:reference, decoded} | {:literal, raw_token}` units until
  # both sides are empty. Which element it keeps depends on the kind: a
  # reference contributes its *expanded* text (`&#10;` -> `"\n"`, exempt from
  # 3.3.3's whitespace rule); a literal contributes its *raw* text (`"\r\n"`,
  # which on this pre-normalization pass is also its expanded text, since Saxy
  # applies no 2.11 either).
  #
  # The `("", "", units)` base clause must come first: a `raw` and `value`
  # that empty together are done, and one that empties alone falls through to
  # `next_unit/2`, which desyncs on it - the same rule `walk_spans/7` applies.
  # Units accumulate reversed, which is why `normalize_attribute_value/3`
  # reverses before folding.
  #
  # The arity-3 clause is the attribute path's entry point, unchanged in
  # behavior from before this function grew a mode and a unit function: it
  # threads a constant `:none` mode through `attribute_unit/3`, a thin adapter
  # that gives `next_unit/2` the arity-3-in/7-tuple-out shape the shared
  # recursion (arity 5, below) calls with. `normalize_character_data/3` is the
  # other caller, threading a real `:text`/`:cdata` mode through
  # `next_text_unit/3` instead - the text walk needs to know whether it is
  # inside an unclosed `<![CDATA[`, which neither `raw` nor `value` alone
  # carries.
  defp walk_units(raw, value, units),
    do: walk_units(raw, value, :none, units, &attribute_unit/3)

  defp attribute_unit(raw, value, mode) do
    case next_unit(raw, value) do
      :desync ->
        :desync

      {:ok, kind, raw_token, expanded, raw_rest, value_rest} ->
        {:ok, kind, raw_token, expanded, raw_rest, value_rest, mode}
    end
  end

  defp walk_units("", "", _mode, units, _next), do: {:ok, units}

  defp walk_units(raw, value, mode, units, next) do
    case next.(raw, value, mode) do
      :desync ->
        :desync

      # A raw-only construct (a comment, a PI, or a CDATA delimiter)
      # contributes no *content* unit, but it does break raw adjacency: a
      # `:boundary` marker goes on the list so `fold_units/2` cannot pair a
      # `\r` before it with a `\n` after it as one CRLF, the way it would if
      # the two literal units simply sat next to each other. This is what
      # makes `i\r<!--c-->\nj` fold to `"i\n\nj"` (CR alone, then LF alone)
      # rather than `"i\nj"` (CR+LF as one pair) - the case ADR-0045's
      # investigation used to show a value-only fold is wrong. Only the mode
      # may move across it (`:text` <-> `:cdata`).
      {:ok, :skip, _raw_token, _expanded, raw_rest, value_rest, mode} ->
        walk_units(raw_rest, value_rest, mode, [:boundary | units], next)

      {:ok, :reference, _raw_token, decoded, raw_rest, value_rest, mode} ->
        walk_units(raw_rest, value_rest, mode, [{:reference, decoded} | units], next)

      {:ok, :literal, raw_token, _expanded, raw_rest, value_rest, mode} ->
        walk_units(raw_rest, value_rest, mode, [{:literal, raw_token} | units], next)
    end
  end

  # The text-walk unit rule: `(raw, value, mode)` where `mode` is `:text` or
  # `:cdata`. In `:text` mode, the three raw-only constructs a text span can
  # straddle (ADR-0045 item 2) are recognized first, each validated with
  # `skip?/3` before being believed - the same validate-before-believing
  # posture `next_unit/2` uses for a reference decode - and otherwise this
  # delegates to `next_unit/2` for plain characters and entity references.
  # `<![CDATA[` switches the mode to `:cdata` and contributes nothing; its
  # matching `]]>` (recognized only in `:cdata` mode, below) switches back.
  # DOCTYPE is on `Markup.scan/1`'s skip list too but not here: it can only
  # appear in the prolog, never inside character data.
  defp next_text_unit(raw, value, :text) do
    cond do
      skip?(raw, value, "<![CDATA[") ->
        consume_skip(raw, value, "<![CDATA[", :cdata)

      skip?(raw, value, "<!--") ->
        skip_through(raw, value, "<!--", "-->", :text)

      skip?(raw, value, "<?") ->
        skip_through(raw, value, "<?", "?>", :text)

      true ->
        tag_mode(next_unit(raw, value), :text)
    end
  end

  # Inside a CDATA section: `]]>` closes it (raw-only, switches back to
  # `:text`); everything else is walked as identical codepoints on both
  # sides, with no reference decoding. Routing the interior through
  # `next_unit/2` would decode a raw `&amp;` to `"&"`, find that `value`
  # (which spells `&amp;` out literally inside a CDATA section) does start
  # with `"&"`, and consume five raw bytes against one value byte - a
  # mispairing. The mode threaded by `walk_units/5` is what keeps the
  # interior out of that path.
  defp next_text_unit(raw, value, :cdata) do
    if skip?(raw, value, "]]>") do
      consume_skip(raw, value, "]]>", :text)
    else
      cdata_literal(raw, value)
    end
  end

  # A construct is only taken as raw-only when the expanded value does not
  # start with the same literal text - mirrors `next_unit/2`'s
  # validate-before-believing rule (`String.starts_with?/2` there) and is what
  # keeps this deterministic: a literal `<` cannot occur in well-formed
  # character data outside these three constructs, so the check is normally
  # vacuous, but it is the same discipline this module applies everywhere
  # else rather than a rule this walk alone gets to skip.
  defp skip?(raw, value, literal) do
    String.starts_with?(raw, literal) and not String.starts_with?(value, literal)
  end

  defp consume_skip(raw, value, token, mode) do
    raw_rest = binary_part(raw, byte_size(token), byte_size(raw) - byte_size(token))
    {:ok, :skip, token, "", raw_rest, value, mode}
  end

  # Consumes from `open` through the first `close` found in `raw`, as one
  # raw-only skip unit; `value` is untouched, since the scanner already
  # elided the whole construct from it. `:nomatch` (an unterminated comment
  # or PI) desyncs rather than consuming past the end of `raw` - the raw slice
  # and `value` were built from the same completed parse, so this is not
  # expected to fire on real input.
  defp skip_through(raw, value, open, close, mode) do
    after_open = binary_part(raw, byte_size(open), byte_size(raw) - byte_size(open))

    case :binary.match(after_open, close) do
      {index, close_length} ->
        total = byte_size(open) + index + close_length
        token = binary_part(raw, 0, total)
        raw_rest = binary_part(raw, total, byte_size(raw) - total)
        {:ok, :skip, token, "", raw_rest, value, mode}

      :nomatch ->
        :desync
    end
  end

  # One codepoint from each side inside a CDATA section, which must be
  # identical - no reference decoding, no TAB/LF/CR-versus-space
  # normalization (that is 3.3.3, attribute-specific). Anything else desyncs.
  defp cdata_literal(raw, value) do
    with {raw_cp, raw_rest} <- String.next_codepoint(raw),
         {value_cp, value_rest} <- String.next_codepoint(value),
         true <- raw_cp == value_cp do
      {:ok, :literal, raw_cp, value_cp, raw_rest, value_rest, :cdata}
    else
      _mismatch -> :desync
    end
  end

  # `next_unit/2` never produces a `:skip` unit; the arity-6 clause gives it
  # the arity-7-tuple shape `walk_units/5`'s recursion calls with, threading
  # `mode` through unchanged (`:text` never becomes `:cdata` except through
  # the `<![CDATA[` delimiter itself, handled above rather than here).
  defp tag_mode(:desync, _mode), do: :desync

  defp tag_mode({:ok, kind, raw_token, expanded, raw_rest, value_rest}, mode),
    do: {:ok, kind, raw_token, expanded, raw_rest, value_rest, mode}

  defp normalize_units([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # 2.11: a literal CRLF is one line break, so one space - never two. Two
  # clauses because the pair can arrive either way: as two units, which is
  # what happens on this pass (Saxy applies no 2.11, so raw "\r\n" pairs
  # against a value that also spells "\r\n" and walks as two
  # identical-codepoint units), or as `resolve_span/4`'s single pair token,
  # which cannot fire against an unnormalized value but is matched so the
  # fold does not depend on that staying true.
  defp normalize_units([{:literal, "\r"}, {:literal, "\n"} | rest], acc),
    do: normalize_units(rest, [" " | acc])

  defp normalize_units([{:literal, "\r\n"} | rest], acc), do: normalize_units(rest, [" " | acc])

  # 3.3.3: "For a white space character (#x20, #xD, #xA, #x9), append a space
  # character (#x20) to the normalized value."
  defp normalize_units([{:literal, ws} | rest], acc) when ws in [" ", "\t", "\n", "\r"],
    do: normalize_units(rest, [" " | acc])

  defp normalize_units([{:literal, other} | rest], acc), do: normalize_units(rest, [other | acc])

  # 3.3.3: "For a character reference, append the referenced character to the
  # normalized value." A reference is exempt from the whitespace rule - that
  # is the whole distinction this walk exists to preserve.
  defp normalize_units([{:reference, decoded} | rest], acc),
    do: normalize_units(rest, [decoded | acc])

  defp fold_units([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # A raw-only construct's boundary contributes no text of its own, but its
  # presence in the list (rather than being dropped during the walk) is what
  # stops the CRLF-pairing clauses below from matching across it - see
  # `walk_units/5`'s `:skip` clause.
  defp fold_units([:boundary | rest], acc), do: fold_units(rest, acc)

  # 2.11 folds a literal CRLF and a lone literal CR to one #xA - nothing else
  # is touched, since 3.3.3's whitespace-to-space mapping is
  # attribute-specific and never applies to character data (ADR-0045 item 1),
  # so a TAB and a folded newline both survive as themselves. Two clauses for
  # the pair, for the same reason `normalize_units/2` has two: the pair
  # arrives as two identical-codepoint units on a real parse (Saxy applies no
  # 2.11, so raw "\r\n" pairs against a value that also spells "\r\n"), or as
  # a single `"\r\n"` token, which cannot fire against Saxy's unfolded value
  # but is matched anyway so the fold does not depend on that staying true.
  defp fold_units([{:literal, "\r"}, {:literal, "\n"} | rest], acc),
    do: fold_units(rest, ["\n" | acc])

  defp fold_units([{:literal, "\r\n"} | rest], acc), do: fold_units(rest, ["\n" | acc])

  # The lone-CR half of 2.11's clause.
  defp fold_units([{:literal, "\r"} | rest], acc), do: fold_units(rest, ["\n" | acc])

  defp fold_units([{:literal, other} | rest], acc), do: fold_units(rest, [other | acc])

  # A `\r` decoded from `&#xD;` (or any other reference) is exempt from the
  # fold - the literal-versus-reference distinction 2.11 draws, carried
  # verbatim exactly as `normalize_units/2` carries a reference through 3.3.3.
  defp fold_units([{:reference, decoded} | rest], acc), do: fold_units(rest, [decoded | acc])

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

        {:ok, _kind, raw_token, expanded_codepoint, raw_rest, value_rest} ->
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

  # The five-case unit rule: a decoded reference token (case 1), identical
  # leading codepoints (case 2), a raw CRLF pair versus a single expanded
  # space (case 3, XML 2.11's line-break fold ahead of 3.3.3's normalization -
  # reachable through a real parse since `Attribute.value` is normalized,
  # ADR-0043), a single TAB/LF/CR-versus-space normalization pair (case 4), or
  # desync (case 5). Every decode is validated against `value` before it is
  # believed (`String.starts_with?/2` below), so a malformed or unexpected
  # reference can only ever fall through to case 2/3/4/5, never produce a
  # wrong answer.
  #
  # Tagged `:reference` or `:literal` so `normalize_attribute_value/3` can
  # tell a literal `\n` (must normalize) from an expanded `&#10;` (must not) -
  # a distinction the expanded codepoint alone cannot carry, since both
  # produce `"\n"`. `resolve_span/4`'s walk (`walk_spans/7`) does not need the
  # kind and ignores it.
  defp next_unit(raw, value) do
    case match_reference(raw) do
      {token, decoded} ->
        if String.starts_with?(value, decoded) do
          raw_rest = binary_part(raw, byte_size(token), byte_size(raw) - byte_size(token))

          value_rest =
            binary_part(value, byte_size(decoded), byte_size(value) - byte_size(decoded))

          {:ok, :reference, token, decoded, raw_rest, value_rest}
        else
          tag_literal(next_unit_plain(raw, value))
        end

      nil ->
        tag_literal(next_unit_plain(raw, value))
    end
  end

  # `next_unit_plain/2` never produces a reference, so the tag is a constant
  # here. The kind is what lets the normalization fold apply 3.3.3's
  # whitespace rule to a literal `\n` while exempting an expanded `&#10;` -
  # the expanded codepoint is identical in both cases, so the distinction
  # cannot be recovered downstream.
  defp tag_literal(:desync), do: :desync

  defp tag_literal({:ok, raw_token, expanded_codepoint, raw_rest, value_rest}),
    do: {:ok, :literal, raw_token, expanded_codepoint, raw_rest, value_rest}

  defp next_unit_plain(raw, value) do
    with {raw_cp, raw_rest} <- String.next_codepoint(raw),
         {value_cp, value_rest} <- String.next_codepoint(value) do
      cond do
        raw_cp == value_cp ->
          {:ok, raw_cp, value_cp, raw_rest, value_rest}

        # 2.11 folds a literal CRLF to one #xA before 3.3.3 maps it to one
        # #x20, so two raw codepoints pair with a single expanded space. Must
        # follow the identical-codepoint branch: an unnormalized value still
        # spells "\r\n" and has to walk as two plain units.
        raw_cp == "\r" and value_cp == " " and String.starts_with?(raw_rest, "\n") ->
          {:ok, "\r\n", value_cp, binary_part(raw_rest, 1, byte_size(raw_rest) - 1), value_rest}

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
         <<_rest::binary>> = decoded <- decode_reference(body) do
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
  # a time - `str` is a single plain codepoint, a raw CRLF pair, or a whole
  # reference token (`&lt;`, `&#10;`); a reference token never contains an
  # actual newline byte, so `\n` is only ever reached via the plain/CRLF/
  # normalize cases.
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
