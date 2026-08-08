defmodule Statifier.Lowering.ErrorTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering.Error
  alias Statifier.Parser.Location

  defp location do
    %Location{
      start_line: 1,
      start_column: 1,
      start_offset: 0,
      end_line: 1,
      end_column: 5,
      end_offset: 4
    }
  end

  describe "unsupported/2" do
    # sabotage: `unsupported/2` builds `{:unsupported_element, "?"}` instead
    # of tagging the reason with the given `name` -> the reason assertion
    # below reddens
    test "carries the element name and the given location" do
      error = Error.unsupported("send", location())

      assert %Error{reason: {:unsupported_element, "send"}, location: loc} = error
      assert loc == location()
      assert error.message =~ "send"
    end
  end

  describe "misplaced/3" do
    # sabotage: `misplaced/3` swaps its `name` and `parent` arguments when
    # building the reason tuple -> the reason assertion below reddens
    test "carries the element name and its parent's name" do
      error = Error.misplaced("state", "log", location())

      assert %Error{reason: {:misplaced_element, "state", "log"}} = error
      assert error.message =~ "state"
      assert error.message =~ "log"
    end
  end

  describe "stray_text/2" do
    # sabotage: `stray_text/2` stores the untrimmed `text` in the reason
    # tuple instead of the trimmed run -> the reason assertion below reddens
    test "trims the text before storing it in the reason" do
      error = Error.stray_text("  hello world  ", location())

      assert %Error{reason: {:stray_text, "hello world"}} = error
    end

    # sabotage: the truncated-preview branch is dropped so the full text is
    # always embedded in `message` -> this test reddens on a long run
    # because the message stops being "readable" (it contains the ellipsis
    # rather than the full 80-character run)
    test "truncates a long run to a readable prefix in the message" do
      long_text = String.duplicate("x", 80)

      error = Error.stray_text(long_text, location())

      assert error.message =~ "..."
      refute error.message =~ long_text
    end
  end

  describe "unexpected_root/2" do
    # sabotage: `unexpected_root/2` hardcodes `"scxml"` as the reason's name
    # instead of using the given `name` -> the reason assertion below
    # reddens
    test "carries the offending root element's name" do
      error = Error.unexpected_root("foo", location())

      assert %Error{reason: {:unexpected_root, "foo"}} = error
      assert error.message =~ "foo"
    end
  end
end
