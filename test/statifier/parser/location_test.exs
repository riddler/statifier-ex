defmodule Statifier.Parser.LocationTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser.Location

  describe "at_offset/2" do
    # sabotage: line_and_column/1 seeds column with `String.length(last_line)`
    # instead of `+ 1` -> the offset-0 case reddens (column 0 instead of 1)
    test "offset 0 is line 1, column 1" do
      assert Location.at_offset("<scxml/>", 0) == %Location{
               start_line: 1,
               start_column: 1,
               start_offset: 0,
               end_line: 1,
               end_column: 1,
               end_offset: 0
             }
    end

    # sabotage: line_and_column/1 splits on "\r\n" instead of "\n" -> this
    # test reddens (line stays 1 instead of advancing to 2)
    test "counts a newline crossed by the prefix" do
      source = "line one\nline two"
      offset = byte_size("line one\nli")

      assert Location.at_offset(source, offset) == %Location{
               start_line: 2,
               start_column: 3,
               start_offset: offset,
               end_line: 2,
               end_column: 3,
               end_offset: offset
             }
    end

    # sabotage: line_and_column/1 counts `byte_size(last_line)` instead of
    # `String.length(last_line)` -> this reddens (column overshoots since
    # each of the two non-ASCII codepoints is more than one byte)
    test "counts codepoints, not bytes, for non-ASCII text on the line" do
      source = "café <scxml/>"
      offset = byte_size("café ")

      location = Location.at_offset(source, offset)

      assert location.start_line == 1
      # "café " is 5 codepoints (c, a, f, é, space), so column 6 - byte
      # offset would put this at column 7 since "é" is 2 bytes in UTF-8.
      assert location.start_column == 6
      assert location.start_offset == offset
    end

    # sabotage: n/a - pins that at_offset/2 accepts the full source length
    # (one past the last valid index), a boundary case/1 above does not
    # exercise; asserts a documented input shape, not a computed behavior
    test "accepts an offset at the end of the source" do
      source = "<a/>"

      location = Location.at_offset(source, byte_size(source))

      assert location.start_offset == byte_size(source)
      assert location.start_line == 1
      assert location.start_column == byte_size(source) + 1
    end
  end

  describe "slice/2" do
    # sabotage: slice/2 uses `end_offset` instead of `end_offset - start_offset`
    # as the length argument -> this reddens (raises ArgumentError from
    # binary_part/3 on an out-of-range length, or returns the wrong text)
    test "returns the exact bytes a span covers" do
      source = "<state id=\"s1\"/>"

      location = %Location{
        start_line: 1,
        start_column: 2,
        start_offset: 1,
        end_line: 1,
        end_column: 7,
        end_offset: 6
      }

      assert Location.slice(location, source) == "state"
    end

    # sabotage: n/a - a zero-width span is an at_offset/2 output shape, and
    # this pins slice/2's behavior on it rather than computing anything new
    test "returns an empty string for a zero-width span" do
      source = "<scxml/>"
      location = Location.at_offset(source, 3)

      assert Location.slice(location, source) == ""
    end
  end
end
