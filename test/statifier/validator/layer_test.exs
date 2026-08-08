defmodule Statifier.Validator.LayerTest do
  use ExUnit.Case, async: true

  # The mechanical form of "every check gets a stable error code"
  # (`test/statifier/lowering/layer_test.exs`'s own AST-walk technique,
  # adapted): `Statifier.Validator.Error`'s `@type reason` union is the
  # source of truth for every tag; every tag must have exactly one
  # constructor function producing it, no two constructor functions may
  # produce the same tag, and every tag must actually be produced (called)
  # by some check module under `lib/statifier/validator/checks/`.
  @error_source "lib/statifier/validator/error.ex"
  @check_sources Path.wildcard("lib/statifier/validator/checks/*.ex") |> Enum.sort()

  defp error_ast do
    @error_source |> File.read!() |> Code.string_to_quoted!()
  end

  # The reason union's tags, read straight from `@type reason :: ...`. A
  # 2-element tuple type like `{:duplicate_id, id :: binary()}` is its own
  # AST node; a 3+-element one like `{:transition_count, owner, count}` is
  # wrapped in `{:{}, _, elements}` - both are unwrapped to their leading
  # atom the same way.
  defp reason_union_tags do
    {_ast, tags} =
      error_ast()
      |> Macro.prewalk([], fn
        {:@, _meta,
         [{:type, _type_meta, [{:"::", _op_meta, [{:reason, _reason_meta, nil}, union]}]}]} =
            node,
        acc ->
          {node, tuple_tags(union) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(tags)
  end

  defp tuple_tags({:|, _meta, [left, right]}), do: tuple_tags(left) ++ tuple_tags(right)
  defp tuple_tags({:{}, _meta, [tag | _rest]}) when is_atom(tag), do: [tag]
  defp tuple_tags({tag, _second}) when is_atom(tag), do: [tag]
  defp tuple_tags(_other), do: []

  # Every top-level `def` in `error.ex` whose body builds a
  # `%Statifier.Validator.Error{}` struct literal carrying a `reason:` key,
  # paired with the tag that literal's reason tuple leads with. `code/1`
  # (which returns `elem(reason, 0)`, not a struct literal) and the private
  # message helpers naturally produce no pair here.
  defp constructor_tag_pairs do
    {_ast, pairs} =
      error_ast()
      |> Macro.prewalk([], fn
        {:def, _meta, [signature, [do: body]]} = node, acc ->
          {node, struct_tag_pairs(body, fun_name(signature)) ++ acc}

        node, acc ->
          {node, acc}
      end)

    pairs
  end

  defp fun_name({:when, _meta, [inner, _guard]}), do: fun_name(inner)
  defp fun_name({name, _meta, _args}) when is_atom(name), do: name

  defp struct_tag_pairs(body, fun_name) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:%, _meta, [{:__MODULE__, _module_meta, _module_ctx}, {:%{}, _map_meta, kvs}]} = node,
        acc ->
          case Keyword.get(kvs, :reason) do
            nil -> {node, acc}
            reason_expr -> {node, [{fun_name, hd(tuple_tags(reason_expr))} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Every `Error.<fun>(...)` remote call reachable anywhere in a check
  # module's AST - inside a `@spec`'s `Error.owner()` counts too, but since
  # `:owner` and `:t` never appear as a constructor name in
  # `constructor_tag_pairs/0`, they drop out when the two are intersected
  # below rather than needing to be filtered out here.
  defp called_error_functions(path) do
    {_ast, calls} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Error]}, fun]}, _call_meta, _args} =
            node,
        acc
        when is_atom(fun) ->
          {node, [fun | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # sabotage: n/a - a fixture loader, asserting only that the source lists
  # the guard below depends on still match the validator layer's modules;
  # no lib/ behavior
  test "the guard reads the validator's error module and every check module" do
    assert @error_source == "lib/statifier/validator/error.ex"
    assert "lib/statifier/validator/checks/ids.ex" in @check_sources
    assert "lib/statifier/validator/checks/boilerplate.ex" in @check_sources
    assert "lib/statifier/validator/checks/default_transition.ex" in @check_sources
    assert length(@check_sources) >= 9
  end

  # sabotage: n/a - this guard walks `error.ex`'s own AST (the reason type
  # union and its constructor functions) at test time; it asserts a static
  # structural property of the source (one constructor per reason tag,
  # never two producing the same tag) rather than any runtime behavior a
  # caller of `lib/` observes. Per docs/testing.md's exemption for harness
  # plumbing that asserts no `lib/` behavior.
  test "every reason tag has exactly one constructor, and no two constructors share a tag" do
    reason_tags = reason_union_tags()
    pairs = constructor_tag_pairs()

    by_tag = Enum.group_by(pairs, fn {_fun, tag} -> tag end, fn {fun, _tag} -> fun end)

    assert Enum.sort(Map.keys(by_tag)) == Enum.sort(reason_tags)

    duplicated = for {tag, funs} <- by_tag, length(Enum.uniq(funs)) > 1, do: {tag, funs}
    assert duplicated == []
  end

  # sabotage: n/a - same static-structure category as the test above (which
  # constructor a `reason:` tuple corresponds to is a property of
  # `error.ex`'s own source, not of any function's runtime output); this
  # test additionally scans the check modules' source for which
  # constructors they call, again a structural read rather than an
  # invocation of `lib/` code.
  test "every reason tag is produced by some check module" do
    reason_tags = reason_union_tags()
    tag_by_fun = Map.new(constructor_tag_pairs())

    called_tags =
      for path <- @check_sources,
          fun <- called_error_functions(path),
          Map.has_key?(tag_by_fun, fun),
          uniq: true,
          do: Map.fetch!(tag_by_fun, fun)

    assert Enum.sort(Enum.uniq(called_tags)) == Enum.sort(reason_tags)
  end
end
