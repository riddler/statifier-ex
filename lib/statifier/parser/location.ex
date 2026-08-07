defmodule Statifier.Parser.Location do
  @moduledoc """
  A source span: 1-based line/column (columns counted in Unicode codepoints),
  0-based byte offsets, exclusive end - the shape ADR-0014 fixed for
  expression spans, used here for XML nodes so the two compose.

  Keeping both line/column and byte offsets is what makes ADR-0014's
  attribute-relative expression spans translatable into document positions by
  plain arithmetic: `value_location.start_offset + span.start` is a byte
  offset, convertible back to a line/column with `at_offset/2` if needed.
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

  defp line_and_column(prefix) do
    lines = String.split(prefix, "\n")
    line = length(lines)
    column = (lines |> List.last() |> String.length()) + 1

    {line, column}
  end
end
