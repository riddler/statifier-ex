defmodule Statifier.Validator.Checks.DuplicateAttributes do
  # Hidden on purpose: unlike its sibling checks this module is not part of
  # the documented surface. What a host reads is the reason
  # (`Statifier.Validator.Error.duplicate_attribute/3`) through
  # `Statifier.Validator.validate/3`; the check that produces it is an
  # internal step.
  @moduledoc false

  # XML 1.0 3.1, well-formedness constraint "Unique Att Spec": "An attribute
  # name MUST NOT appear more than once in the same start-tag or
  # empty-element tag." The parser keeps every repeated attribute
  # (`Statifier.Parser.DOM.Element`'s `attributes` preserve duplicates) and
  # lowering keeps one of them, so by the time a `%Document{}` reaches the
  # validator the repeat is gone from the typed structs - an
  # `attribute_locations` map holds one span per name. The repeat survives
  # only in the source, so this check re-scans `context.source` with the
  # parser's own scanner, `Statifier.Parser.Markup.scan/1`, whose start-tag
  # records carry every attribute in document order with its span.
  #
  # Names are compared as the raw qualified bytes, prefix included, exactly
  # as the DOM stores them. The first occurrence of a name on a tag is
  # canonical and reports nothing; every later occurrence on the same tag
  # gets its own error at that occurrence's span, as `Checks.Ids` treats a
  # repeated id. Every start tag in the source is scanned, including markup
  # inside a `<content>` or a `<data>`, since the constraint is the XML
  # document's, not the SCXML vocabulary's.

  alias Statifier.Document
  alias Statifier.Parser.Markup
  alias Statifier.Validator.{Context, Error}

  @doc false
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{}, %Context{source: source}) do
    source
    |> Markup.scan()
    |> Enum.filter(&match?(%Markup{kind: :start}, &1))
    |> Enum.flat_map(&tag_errors/1)
  end

  defp tag_errors(%Markup{name: element, attributes: attributes}) do
    {errors, _seen} =
      Enum.reduce(attributes, {[], MapSet.new()}, fn %{name: name, location: location},
                                                     {errors, seen} ->
        if MapSet.member?(seen, name) do
          {[Error.duplicate_attribute(element, name, location) | errors], seen}
        else
          {errors, MapSet.put(seen, name)}
        end
      end)

    Enum.reverse(errors)
  end
end
