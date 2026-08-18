defmodule Statifier.Parser.ParseErrorTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser
  alias Statifier.Parser.{Location, ParseError}

  # One case per Saxy reason `parse/1` can actually reach. Each fixture puts
  # the failure off line 1 where it can, so a location that merely defaulted
  # to the top of the document cannot pass.
  describe "parse/1 - the malformed-input matrix" do
    # sabotage: from_saxy/2 discards Saxy's reason for a bare `:parse_error`
    # atom -> the reason match reddens
    test "a mismatched closing tag reports Saxy's reason and the closing tag's line" do
      xml = """
      <a>
          <b>
          </c>
      </a>
      """

      assert {:error, %ParseError{reason: {:wrong_closing_tag, "b", "c"}} = error} =
               Parser.parse(xml)

      assert %Location{start_line: 3, start_column: 9} = error.location
    end

    # sabotage: from_saxy/2's integer-position clause stores
    # `byte_offset: position - 1` -> the end-of-input offset assertion reddens
    test "input truncated mid-tag reports a token reason at the end of the input" do
      xml = "<a"

      assert {:error, %ParseError{reason: {:token, :name_start_char}} = error} = Parser.parse(xml)

      assert error.byte_offset == byte_size(xml)
      assert %Location{start_line: 1, start_column: 3} = error.location
    end

    # sabotage: from_saxy/2 builds its location with
    # `Location.at_offset(source, 0)` -> the reported line collapses to 1,
    # reddening the line-2 assertion
    test "an unquoted attribute value reports a token reason at the value" do
      xml = """
      <a>
          <b x=1/>
      </a>
      """

      assert {:error, %ParseError{reason: {:token, :quote}} = error} = Parser.parse(xml)

      assert %Location{start_line: 2, start_column: 10} = error.location
    end

    # sabotage: parse/1's `{:error, %Saxy.ParseError{}}` branch returns the
    # Saxy struct unconverted -> the %ParseError{} match reddens
    test "a second root element reports a token reason at the second root" do
      xml = """
      <a/>
      <b/>
      """

      assert {:error, %ParseError{reason: {:token, :misc}} = error} = Parser.parse(xml)

      assert %Location{start_line: 2, start_column: 2} = error.location
      assert binary_part(xml, error.byte_offset, 1) == "b"
    end

    # sabotage: from_saxy/2 stores `byte_offset: 0` -> the raw-offset
    # assertion reddens while the location keeps looking right
    test "a non-UTF-8 encoding declaration reports the declared encoding" do
      xml = """
      <?xml version="1.0" encoding="ISO-8859-1"?>
      <a/>
      """

      assert {:error, %ParseError{reason: {:invalid_encoding, "ISO-8859-1"}} = error} =
               Parser.parse(xml)

      assert error.byte_offset == 30
      assert %Location{start_line: 1, start_column: 31} = error.location
    end

    # sabotage: from_saxy/2 builds its location with
    # `Location.at_offset(source, position + 1)` -> every column is one too
    # far right, reddening the column assertion
    test "a processing instruction targeting a reserved name reports its target" do
      xml = """
      <a>
          <?xml v?>
      </a>
      """

      assert {:error, %ParseError{reason: {:invalid_pi, "xml"}} = error} = Parser.parse(xml)

      assert %Location{start_line: 2, start_column: 7} = error.location
    end
  end

  describe "from_saxy/2" do
    # sabotage: from_saxy/2's nil-position clause returns `byte_offset: 0`
    # instead of nil -> the nil assertion reddens
    test "a nil position yields a nil location and a nil byte offset" do
      saxy_error = %Saxy.ParseError{reason: {:bad_return, {:characters, :oops}}, binary: nil}

      assert %ParseError{location: nil, byte_offset: nil} =
               error = ParseError.from_saxy(saxy_error, "<a/>")

      assert error.reason == {:bad_return, {:characters, :oops}}
    end
  end

  describe "parse/1 - totality" do
    # sabotage: parse/1 drops the `rescue` clause from run_saxy/2 -> the
    # truncated-comment and truncated-PI inputs raise a CaseClauseError out
    # of Saxy 1.6.1, reddening the loop
    test "hostile input is a returned error, never an exception" do
      hostile = [
        "",
        "   \n\t ",
        "<",
        ~s(<a x="1></a>),
        "]]>",
        "<!-- unterminated",
        "<?pi",
        "<a><![CDATA[ oops</a>",
        "<!DOCTYPE a [",
        "</a>",
        ~s(<a b='c"/>),
        "<a =x>",
        ~s(<a b c="1"/>),
        "<a b=",
        ~s(<a b=1 c="2">)
      ]

      for xml <- hostile do
        assert match?({:error, %ParseError{}}, Parser.parse(xml)),
               "expected an error tuple for #{inspect(xml)}"
      end
    end

    # sabotage: ParseError.from_exception/1 stores the raw exception as its
    # `message` instead of `Exception.message(exception)` -> the binary
    # message assertion reddens
    test "an exception escaping Saxy is converted, not propagated" do
      assert {:error, %ParseError{reason: {:saxy_crash, %CaseClauseError{}}} = error} =
               Parser.parse("<!-- unterminated")

      assert is_binary(error.message)
      assert error.location == nil
    end
  end
end
