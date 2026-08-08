defmodule Statifier.Validator.Checks.Boilerplate do
  @moduledoc """
  Checks 9 and 10 (spec 3.2.1), deferred here by st-700 (relaxed parsing) -
  see `docs/plans/260808-st-l5k.5-document-validator.md` Decision 2 and the
  bead's own notes. Lowering accepts a boilerplate-free `<scxml>` fragment
  unconditionally (`Statifier.Lowering.Namespace.scxml_vocabulary?/1`
  treats a `nil` namespace as SCXML's own vocabulary), so this is the only
  place in the pipeline that ever refuses one.

  Check 9 reads `document.namespace` - the root element's **resolved** URI
  (`Statifier.Document`'s moduledoc), not the literal `xmlns` attribute -
  so a spec-conformant prefix-declared root such as
  `<s:scxml xmlns:s="http://www.w3.org/2005/07/scxml">` passes clean even
  though its own `xmlns` field is `nil`. Check 10 reads `document.version`
  directly; v1's regex-based presence check is deliberately not repeated
  here, so a written-but-wrong `version="2.0"` is reported rather than
  silently accepted.

  Both checks share the same span preference: the written attribute's own
  value span when the attribute was written, `document.location` (the
  `<scxml>` start tag) otherwise - covering both the absent case and the
  prefixed-`xmlns` case, where the declaration is `xmlns:s=` and has no
  `attribute_locations[:xmlns]` entry.
  """

  alias Statifier.Document
  alias Statifier.Lowering.Namespace
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{} = document, %Context{}) do
    check_namespace(document) ++ check_version(document)
  end

  defp check_namespace(%Document{namespace: namespace} = document) do
    if namespace == Namespace.scxml_namespace() do
      []
    else
      [Error.bad_namespace(namespace, span(document, :xmlns))]
    end
  end

  defp check_version(%Document{version: version} = document) do
    if version == "1.0" do
      []
    else
      [Error.bad_version(version, span(document, :version))]
    end
  end

  defp span(%Document{attribute_locations: attribute_locations, location: location}, key) do
    Map.get(attribute_locations, key, location)
  end
end
