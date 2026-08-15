defmodule Statifier.Lowering.UnsupportedTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser
  alias Statifier.Parser.Location

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  # Exactly one error, naming `name`, whose own location slices back to
  # `name`'s own start tag - not its parent's.
  defp assert_unsupported(xml, name) do
    assert {:error, [%Error{reason: {:unsupported_element, ^name}} = error]} =
             xml |> parse!() |> Lowering.lower()

    slice = Location.slice(error.location, xml)

    assert slice =~ ~r/\A<#{Regex.escape(name)}[\s\/>]/,
           "#{name}'s reported location is not its own: #{inspect(slice)}"

    error
  end

  describe "elements outside the supported set are rejected by name, at their own location" do
    # `<datamodel>` and `<data>` moved from this deferred set to the
    # supported set in st-af3.3 Phase 1 - see
    # `test/statifier/lowering/datamodel_test.exs` for their own coverage.
    # `<assign>` moved the same way in st-af3.4 Phase 1 - see
    # `test/statifier/lowering/content_test.exs` for its own coverage.
    # `<if>`/`<elseif>`/`<else>` moved the same way in st-af3.5 Phase 2 - see
    # `test/statifier/lowering/content_test.exs` for their own coverage.
    # `<script>` moved the same way - see
    # `test/statifier/lowering/content_test.exs` for its own coverage.
    # `<invoke>` moved the same way - see
    # `test/statifier/lowering/invoke_test.exs` for its own coverage.

    # `<send>` moved the same way - see
    # `test/statifier/lowering/send_test.exs` for its own coverage.
    # `<cancel>` moved the same way - see
    # `test/statifier/lowering/cancel_test.exs` for its own coverage.

    # `<foreach>` moved from this deferred set to the supported set in
    # st-af3.6 Phase 1 - see `test/statifier/lowering/content_test.exs` for
    # its own coverage. `<param>` moved the same way in st-af3.7 Phase 3 -
    # see `test/statifier/lowering/donedata_test.exs` for its own coverage.
  end
end
