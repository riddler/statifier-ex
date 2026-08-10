defmodule Statifier.Document.LayerTest do
  use ExUnit.Case, async: true

  # Three structural properties of the Document layer - every node carries a
  # location, no Predicator dependency, no document_order integer - enforced
  # mechanically here rather than left to review.
  @document_sources ["lib/statifier/document.ex" | Path.wildcard("lib/statifier/document/*.ex")]
                    |> Enum.sort()

  # Path -> module name by the same lib/ layout Mix already assumes:
  # lib/statifier/document/state.ex -> Statifier.Document.State.
  # Module.safe_concat/1 refuses to atomize a module that is not already
  # loaded, so this cannot forge a bogus module name at runtime.
  @spec module_for_path(path :: String.t()) :: module()
  defp module_for_path(path) do
    path
    |> Path.rootname()
    |> Path.relative_to("lib")
    |> Path.split()
    |> Enum.map(&Macro.camelize/1)
    |> Module.safe_concat()
  end

  # The @enforce_keys list as written in the source, read from the AST rather
  # than at runtime: compiled struct info does not retain which keys were
  # enforced, only their defaults.
  @spec enforce_keys(path :: String.t()) :: [atom()]
  defp enforce_keys(path) do
    {_ast, keys} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(nil, fn
        {:@, _meta, [{:enforce_keys, _kmeta, [keys]}]} = node, _acc -> {node, keys}
        node, acc -> {node, acc}
      end)

    keys || []
  end

  # Whole-alias matches only, and doc attributes are dropped first, mirroring
  # generic_handler_test.exs: moduledoc prose is allowed to say "Predicator"
  # in an English sentence explaining why the code must not reference it.
  @spec references_predicator?(path :: String.t()) :: boolean()
  defp references_predicator?(path) do
    {_ast, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(false, fn
        {:@, _meta, [{doc_attr, _dmeta, _dargs}]}, acc
        when doc_attr in [:moduledoc, :doc, :typedoc] ->
          {:dropped_doc, acc}

        {:__aliases__, _meta, parts} = node, acc ->
          {node, acc or :Predicator in parts}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # sabotage: n/a - lists .ex files under lib/statifier/document/, no lib/ behavior
  test "the guard reads every module under lib/statifier/document/" do
    assert "lib/statifier/document.ex" in @document_sources
    assert "lib/statifier/document/state.ex" in @document_sources
    assert "lib/statifier/document/block.ex" in @document_sources
    assert length(@document_sources) >= 9
  end

  describe "guard 1: every struct carries a location" do
    # sabotage: drop :location from Block's @enforce_keys -> reddens the enforce_keys(path) assertion for Block
    test "every struct module both has and enforces a :location field" do
      for path <- @document_sources do
        mod = module_for_path(path)

        assert Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0),
               "#{path} did not compile to a struct module (#{inspect(mod)})"

        struct_keys = mod.__struct__() |> Map.from_struct() |> Map.keys()

        assert :location in struct_keys, "#{inspect(mod)} has no :location field"
        assert :location in enforce_keys(path), "#{inspect(mod)} does not enforce :location"
      end
    end
  end

  describe "guard 2: no Predicator in this layer" do
    # sabotage: add `alias Predicator` to Log -> the offending file shows up, reddening the empty-list assertion
    test "no source file in the document layer references Predicator" do
      offenders = for path <- @document_sources, references_predicator?(path), do: path

      assert offenders == []
    end
  end

  describe "guard 3: no document_order" do
    # sabotage: add a document_order field to State's defstruct -> the file shows up, reddening the assertion
    test "no source file in the document layer mentions document_order" do
      offenders =
        for path <- @document_sources,
            String.contains?(File.read!(path), "document_order"),
            do: path

      assert offenders == []
    end
  end
end
