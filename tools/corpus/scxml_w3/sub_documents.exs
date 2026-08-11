defmodule Cases.SubDocuments do
  @moduledoc """
  The W3C IRP manifest marks each <test>'s entry point as <start uri="..."/>
  and every document that test invokes as <dep uri="..."/>. Only <start>
  documents are conformance tests; a <dep> is a fixture some parent loads via
  <invoke src>, and emitting one as a standalone test asserts the parent's
  expected configuration against a document that never reaches it.

  Parsed with a regex rather than xmerl: Mix prunes xmerl from the code path
  (see cases.exs), so an xmerl-based module could not be reached from
  test/corpus/. Both elements occur only inside <test> and only in the uniform
  self-closing single-attribute shape, verified across the whole manifest.
  """

  @role_pattern ~r/<(start|dep)\s+uri="([^"]*)"/

  @spec ids(Path.t()) :: MapSet.t(String.t())
  def ids(manifest_path), do: manifest_path |> File.read!() |> ids_from_string()

  @spec ids_from_string(String.t()) :: MapSet.t(String.t())
  def ids_from_string(manifest) do
    roles =
      @role_pattern
      |> Regex.scan(manifest)
      |> Enum.map(fn [_full, role, uri] -> {role, uri} end)

    starts =
      for {"start", uri} <- roles, into: MapSet.new(), do: Path.basename(uri, ".txml")

    deps =
      for {"dep", uri} <- roles,
          Path.extname(uri) == ".txml",
          into: MapSet.new(),
          do: Path.basename(uri, ".txml")

    MapSet.difference(deps, starts)
  end
end
