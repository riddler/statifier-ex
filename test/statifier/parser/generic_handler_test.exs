defmodule Statifier.Parser.GenericHandlerTest do
  use ExUnit.Case, async: true

  # The bead's "no SCXML-specific clauses in the handler" criterion, made
  # mechanical. It fails the moment someone reaches for the shortcut that
  # produced v1's 73-clause state_stack: the parser layer may not name an
  # element, because the moment it can, a clause per element follows.
  @scxml_element_names ~w(
    scxml state parallel final initial history transition onentry onexit
    datamodel data log raise assign send param content if elseif else
    foreach invoke donedata cancel script
  )

  @parser_sources "lib/statifier/parser/**/*.ex"

  # Whole string literals only. Moduledoc and doc prose in these modules
  # legitimately says "content", "data", and "state" in English sentences, so
  # a substring search would flag the documentation rather than the code. The
  # AST walk drops the doc attributes outright and then compares each
  # remaining literal for equality.
  defp string_literals(path) do
    {_ast, literals} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _meta, [{doc_attribute, _doc_meta, _doc_args}]}, acc
        when doc_attribute in [:moduledoc, :doc, :typedoc] ->
          {:dropped_doc, acc}

        node, acc when is_binary(node) ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    literals
  end

  # sabotage: n/a - a fixture loader, asserting only that the wildcard the
  # guard below depends on still matches the parser modules; no lib/ behavior
  test "the guard reads every module under lib/statifier/parser/" do
    paths = Path.wildcard(@parser_sources)

    assert "lib/statifier/parser/markup.ex" in paths
    assert "lib/statifier/parser/handler.ex" in paths
    assert "lib/statifier/parser/dom/element.ex" in paths
    assert length(paths) >= 8
  end

  # sabotage: Markup.scan/1's scan_start_tag/2 gains a `name == "state"`
  # special case -> the offending literal shows up and the empty-list
  # assertion reddens
  test "no parser module names an SCXML element" do
    offenders =
      for path <- Path.wildcard(@parser_sources),
          literal <- string_literals(path),
          literal in @scxml_element_names,
          do: {path, literal}

    assert offenders == []
  end
end
