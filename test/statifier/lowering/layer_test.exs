defmodule Statifier.Lowering.LayerTest do
  use ExUnit.Case, async: true

  # Decision 10's mechanical defense: a (child, parent) clause matrix cannot
  # satisfy "no SCXML element name appears more than once as a whole string
  # literal across the layer", because every such clause names both a child
  # and a parent. This is the same vocabulary and AST-walk technique as
  # `test/statifier/parser/generic_handler_test.exs`, duplicated rather than
  # shared - `lib/statifier/lowering/` cannot import from `test/`, and the
  # guard belongs to this layer, not the parser's.
  @scxml_element_names ~w(
    scxml state parallel final initial history transition onentry onexit
    datamodel data log raise assign send param content if elseif else
    foreach invoke donedata cancel script
  )

  # `Statifier.Lowering` itself lives at `lib/statifier/lowering.ex`, one
  # level above the `lib/statifier/lowering/` directory the other four
  # modules live under (Decision 1's layout table) - and it is the one file
  # that actually holds the dispatch map's thirteen element-name literals.
  # Excluding it would make the guard blind to exactly the mutation it
  # exists to catch (a duplicated literal split across `lowering.ex` and
  # `builders.ex`), so the source list is the whole layer, matching how
  # `test/statifier/document/layer_test.exs` builds its own list from
  # `lib/statifier/document.ex` plus the wildcard under `lib/statifier/document/`.
  @lowering_sources [
                      "lib/statifier/lowering.ex"
                      | Path.wildcard("lib/statifier/lowering/**/*.ex")
                    ]
                    |> Enum.sort()

  # Unlike `generic_handler_test.exs`'s parser guard (which may say an
  # element name nowhere at all, so any whole-string-literal match is
  # already a violation), this layer's builders legitimately say an element
  # name more than once for reasons that are not the clause matrix: an
  # attribute name that happens to collide with an element name
  # (`Attributes.put_location(:initial, element, "initial")` - "initial" is
  # both), a parent's own name threaded into a `misplaced_element` message
  # (`Error.misplaced(name, "content", location)` inside `build_content/2`),
  # and `content_node_name/1` mapping a struct back to the element name it
  # came from for the same kind of message. None of those is a dispatch
  # clause - they are plain data flowing through ordinary function-call
  # arguments and return values, in the *body* of a function.
  #
  # The clause matrix Decision 10 actually guards against is a name used to
  # **decide dispatch**: a map literal's keys (`@dispatch` itself), or a
  # literal appearing in a `def`/`defp` **head** - its argument patterns or
  # its `when` guard - which is exactly the shape `parent_name == "state"`
  # or `%Element{name: "state"}` would take if a builder grew a
  # parent-aware clause. Scanning only those two positions (not every
  # string literal in the file) is what makes the guard fire on the
  # sabotage below without also failing on the real, committed code it is
  # meant to protect.
  defp dispatch_literals(path) do
    {_ast, literals} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:%{}, _meta, pairs} = node, acc when is_list(pairs) ->
          keys = for {key, _value} <- pairs, is_binary(key), do: key
          {node, keys ++ acc}

        {kind, _meta, [head, _body]} = node, acc when kind in [:def, :defp] ->
          {node, head_literals(head) ++ acc}

        node, acc ->
          {node, acc}
      end)

    literals
  end

  # Every binary literal reachable from a function's head (its argument
  # patterns and, when present, its `when` guard) - never its body, which is
  # where the legitimate reuses above all live.
  defp head_literals(head) do
    {_ast, literals} =
      Macro.prewalk(head, [], fn
        node, acc when is_binary(node) -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    literals
  end

  # sabotage: n/a - a fixture loader, asserting only that the source list the
  # guard below depends on still matches the lowering layer's modules; no
  # lib/ behavior
  test "the guard reads every module in the lowering layer" do
    assert "lib/statifier/lowering.ex" in @lowering_sources
    assert "lib/statifier/lowering/builders.ex" in @lowering_sources
    assert "lib/statifier/lowering/error.ex" in @lowering_sources
    assert "lib/statifier/lowering/attributes.ex" in @lowering_sources
    assert "lib/statifier/lowering/namespace.ex" in @lowering_sources
    assert length(@lowering_sources) >= 5
  end

  # sabotage: `build_transition/2` grows a second argument
  # (`parent_element_name`) and a second clause guarded on it, e.g.
  # `when parent_element_name == "state"` - a literal `"state"` that already
  # appears once as a dispatch-map key in `lowering.ex` - so the same element
  # name now shows up twice across the layer, and the empty-offenders
  # assertion below reddens
  test "no SCXML element name appears more than once as a string literal across the layer" do
    all_names =
      for path <- @lowering_sources,
          literal <- dispatch_literals(path),
          literal in @scxml_element_names,
          do: literal

    offenders =
      all_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    assert offenders == []
  end
end
