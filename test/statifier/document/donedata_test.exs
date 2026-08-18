defmodule Statifier.Document.DonedataTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.{Content, Donedata}
  alias Statifier.Parser.Location

  defp loc do
    %Location{
      start_line: 1,
      start_column: 1,
      start_offset: 0,
      end_line: 1,
      end_column: 12,
      end_offset: 11
    }
  end

  describe "@enforce_keys" do
    # sabotage: drop :location from Donedata's @enforce_keys -> red
    test "struct!/2 with no fields raises ArgumentError naming :location" do
      assert_raise ArgumentError, ~r/:location/, fn -> struct!(Donedata, []) end
    end
  end

  describe "defaults" do
    # sabotage: change Donedata's content default from nil to %Content{} -> red
    test "content defaults to nil" do
      donedata = struct!(Donedata, location: loc())

      assert %Donedata{content: nil} = donedata
    end
  end

  describe "content" do
    # sabotage: drop :content from Donedata's defstruct fields entirely -> red
    test "holds a Content node when the element has one" do
      content = %Content{text: "done", location: loc()}
      donedata = %Donedata{content: content, location: loc()}

      assert %Donedata{content: %Content{text: "done"}} = donedata
    end
  end
end
