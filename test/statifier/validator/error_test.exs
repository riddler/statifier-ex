defmodule Statifier.Validator.ErrorTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser.Location
  alias Statifier.Validator.Error

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

  describe "code/1" do
    # sabotage: code/1 hardcodes :duplicate_id instead of `elem(reason, 0)`
    # -> the second assertion below reddens
    test "returns the reason tuple's tag" do
      assert Error.code({:duplicate_id, "a"}) == :duplicate_id
      assert Error.code({:bad_version, "2.0"}) == :bad_version
    end
  end

  describe "duplicate_id/2" do
    # sabotage: duplicate_id/2 builds {:duplicate_id, "?"} instead of
    # tagging the reason with the given `id` -> the reason assertion below
    # reddens
    test "carries the id and the given location, with a prose message" do
      error = Error.duplicate_id("a", location())

      assert %Error{reason: {:duplicate_id, "a"}, location: loc} = error
      assert loc == location()
      assert error.message =~ "a"
    end
  end
end
