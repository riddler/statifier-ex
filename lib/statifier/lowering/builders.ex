defmodule Statifier.Lowering.Builders do
  @moduledoc """
  One `build_*` function per supported SCXML element, reached through
  `Statifier.Lowering`'s dispatch map - the structural fix for v1's
  903-line, 73-clause `state_stack.ex` (`docs/architecture.md`,
  "adding an element touches one builder").

  Every builder lowers its own children first, through
  `Statifier.Lowering.walk_children/2`, before building its own struct, so
  errors accumulate in document order regardless of nesting depth. No
  builder here takes a parent element name as an argument (Decision 3):
  placement of a tagged child result into a parent's slot is each
  container's own `place/2` (from Phase 2 on), never a fact the child
  itself needs to know.
  """

  alias Statifier.Document
  alias Statifier.Lowering
  alias Statifier.Lowering.Attributes
  alias Statifier.Lowering.Error
  alias Statifier.Parser.DOM.Element

  @binding_values %{"early" => :early, "late" => :late}

  @doc """
  Builds the `%Statifier.Document{}` root from `<scxml>`.

  Reads `initial` (whitespace-split), `name`, `datamodel`, `binding` (atom,
  default `:early`), `version`, and `xmlns`. State children are placed
  starting Phase 2; in this phase every element child of `<scxml>` misses
  the dispatch map and comes back as an `{:unsupported_element, name}`
  error from `walk_children/2` - `<scxml>` has no slot to put anything in
  yet, so its own children are walked only for their errors.
  """
  @spec build_scxml(element :: Element.t(), ctx :: map()) :: {Document.t(), [Error.t()]}
  def build_scxml(%Element{} = element, ctx) do
    {_results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:initial, element, "initial")
      |> Attributes.put_location(:name, element, "name")
      |> Attributes.put_location(:datamodel, element, "datamodel")
      |> Attributes.put_location(:binding, element, "binding")
      |> Attributes.put_location(:version, element, "version")
      |> Attributes.put_location(:xmlns, element, "xmlns")

    document = %Document{
      location: element.location,
      initial: Attributes.list(element, "initial"),
      name: Attributes.value(element, "name"),
      datamodel: Attributes.value(element, "datamodel"),
      binding: Attributes.atom(element, "binding", @binding_values, :early),
      version: Attributes.value(element, "version"),
      xmlns: Attributes.value(element, "xmlns"),
      attribute_locations: attribute_locations
    }

    {document, errors}
  end
end
