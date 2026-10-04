defmodule Statifier.Lowering do
  @moduledoc """
  The second arrow of the parser pipeline: a generic
  `%Statifier.Parser.DOM.Element{}` tree in, a typed `%Statifier.Document{}`
  tree out (`docs/architecture.md`, "Parser: DOM first, then lowering").

  ## The accumulator contract

  `lower/2` performs one traversal. Every builder in
  `Statifier.Lowering.Builders` lowers its children first via
  `walk_children/2`, appending each child's errors to its own in document
  order; `lower/2` sorts the whole accumulated list by
  `location.start_offset` before returning, so the report reads in document
  order regardless of the order a parent happened to emit its own error
  relative to its children's.

  `ctx` also carries `:source` - the source binary being lowered, seeded by
  `lower/2` and copied forward unchanged by `walk_child/4` to every builder
  in the tree. `build_content/2` is the one builder that reads it, to slice
  `<content>`'s markup children (ADR-0041) back out of the original bytes.
  Lowering still never re-parses anything; slicing only reads spans it
  already has.

  A builder that cannot place or build something still returns the best
  partial result it can (or nothing, when it cannot build one at all) so the
  walk keeps going and later errors are still found - but that partial tree
  is never handed back to the caller. `lower/2` returns `{:ok, document}`
  only when the accumulated error list is empty; any non-empty list means
  `{:error, errors}`, full stop, regardless of how much of the tree built
  successfully. Handing back a document that lowering itself does not trust
  would just move the "is this actually usable" question onto every caller.

  ## Dispatch is context-free

  The dispatch map's keys are exactly the supported child element names; no
  `build_*` function in `Builders` takes a parent element name as an
  argument. A builder does not know or care what its parent was - the
  parent, when it exists, is what decides whether the child's tagged
  result has anywhere to go (`Builders.place/3`). The
  parent's own element name is known only to itself, and is used solely to
  word a `{:misplaced_element, name, parent_name}` error about one of *its
  own* children - it is never handed down to a child builder.

  ## Only `<scxml>` may be the root

  `<scxml>` is the one element that may be a document's root, and it is
  never a child. `lower/2` builds it directly and refuses every other root
  name as `{:unexpected_root, local_name}`, whatever that name is, so a
  root such as `<state>` is refused rather than handed to a builder whose
  result has nowhere to go. `<scxml>` is not a key of the dispatch map
  either, so an `<scxml>` at any walked child site (a child that
  `walk_child/4` looks up) misses the map and is reported as
  `{:unsupported_element, name}`, like any other name the map does not
  hold. A builder that reads its element children itself instead of
  walking them answers for an `<scxml>` there as for any other element
  child, as its own `@doc` states; for example, under `<data>` it is a
  `{:misplaced_element, name, "data"}`, and inside `<content>` or
  `<assign>` it is part of the opaque markup slice.

  ## Relaxed input

  Both sites that resolve an element's namespace (`lower/2` for the root,
  `walk_child/4` for each walked child) accept an element with no
  namespace as SCXML's own vocabulary, not only one resolved to the SCXML
  namespace; `walk_child/4` is the one site that looks a name up in the
  dispatch map. `Statifier.Lowering.Namespace.scxml_vocabulary?/1` is the
  mechanism and its moduledoc states the commitment; this is a pointer for
  the reader who starts here instead.
  """

  alias Statifier.Document
  alias Statifier.Lowering.{Builders, Error, Namespace}
  alias Statifier.Parser.DOM.{Element, Text}

  @root "scxml"

  @dispatch %{
    "state" => &Builders.build_state/2,
    "parallel" => &Builders.build_parallel/2,
    "final" => &Builders.build_final/2,
    "history" => &Builders.build_history/2,
    "initial" => &Builders.build_initial/2,
    "transition" => &Builders.build_transition/2,
    "onentry" => &Builders.build_onentry/2,
    "onexit" => &Builders.build_onexit/2,
    "raise" => &Builders.build_raise/2,
    "log" => &Builders.build_log/2,
    "donedata" => &Builders.build_donedata/2,
    "content" => &Builders.build_content/2,
    "param" => &Builders.build_param/2,
    "datamodel" => &Builders.build_datamodel/2,
    "data" => &Builders.build_data/2,
    "assign" => &Builders.build_assign/2,
    "if" => &Builders.build_if/2,
    "elseif" => &Builders.build_elseif/2,
    "else" => &Builders.build_else/2,
    "foreach" => &Builders.build_foreach/2,
    "script" => &Builders.build_script/2,
    "invoke" => &Builders.build_invoke/2,
    "finalize" => &Builders.build_finalize/2,
    "send" => &Builders.build_send/2,
    "cancel" => &Builders.build_cancel/2
  }

  @doc """
  Lowers a generic `%Statifier.Parser.DOM.Element{}` tree - the parsed
  `<scxml>` root - into a typed `%Statifier.Document{}` tree, in one
  traversal that dispatches every child through `Statifier.Lowering.Builders`
  by element name. `source` is the same source binary
  `Statifier.Validator.validate/2` takes; it is seeded into `ctx` under
  `:source` for the one builder that slices bytes out of it.

  Returns `{:ok, document}` only when the whole walk accumulated no errors;
  any error at all, anywhere in the tree, produces `{:error, errors}` with
  the errors sorted into document order - never a partial document, even
  when most of the tree built successfully. An element outside the SCXML
  vocabulary (and not using the relaxed no-namespace fallback) is reported
  as `{:foreign_element, name, uri, location}`; a non-`<scxml>` root name is
  `{:unexpected_root, local_name, location}`, whether or not that name is
  legal as a child (`<state>`, `<transition>`, ...); an `<scxml>` at a
  walked child site is `{:unsupported_element, name, location}`.
  """
  @spec lower(root :: Element.t(), source :: binary()) ::
          {:ok, Document.t()} | {:error, [Error.t()]}
  def lower(%Element{name: name, location: location} = root, source)
      when is_binary(source) do
    scope = Namespace.push(%{}, root)
    {uri, local_name} = Namespace.resolve(name, scope)

    if Namespace.scxml_vocabulary?(uri) do
      if local_name == @root do
        {document, errors} = Builders.build_scxml(root, %{ns_scope: scope, source: source})
        finalize(%{document | namespace: uri}, errors)
      else
        {:error, [Error.unexpected_root(local_name, location)]}
      end
    else
      {:error, [Error.foreign_element(name, uri, location)]}
    end
  end

  @doc false
  # Lowers `element`'s direct children: dispatches each child element through
  # the shared map, or reports it as `{:unsupported_element, name}` when it
  # misses; errors on any non-whitespace `%Text{}` run. Reads the
  # **unfiltered** `children` list rather than `DOM.elements/1`, which
  # filters text out and would silently drop the stray-text rule with it.
  #
  # Returns tagged child results in document order (each builder's own
  # `{slot, struct}` tag) alongside the accumulated errors,
  # so a container builder can fold the results into its own struct via its
  # own `place/2` without this function knowing anything about slots.
  @spec walk_children(element :: Element.t(), ctx :: map()) :: {[term()], [Error.t()]}
  def walk_children(%Element{children: children}, ctx) do
    {results, errors} =
      Enum.reduce(children, {[], []}, fn child, {results, errors} ->
        walk_child(child, ctx, results, errors)
      end)

    {Enum.reverse(results), errors}
  end

  defp walk_child(%Text{value: value, location: location}, _ctx, results, errors) do
    if String.trim(value) == "" do
      {results, errors}
    else
      {results, [Error.stray_text(value, location) | errors]}
    end
  end

  defp walk_child(%Element{name: name, location: location} = element, ctx, results, errors) do
    scope = Namespace.push(Map.get(ctx, :ns_scope, %{}), element)
    {uri, local_name} = Namespace.resolve(name, scope)

    if Namespace.scxml_vocabulary?(uri) do
      child_ctx = Map.put(ctx, :ns_scope, scope)

      case Map.fetch(@dispatch, local_name) do
        {:ok, builder} ->
          {result, child_errors} = builder.(element, child_ctx)
          {[result | results], Enum.reverse(child_errors) ++ errors}

        :error ->
          {results, [Error.unsupported(name, location) | errors]}
      end
    else
      {results, [Error.foreign_element(name, uri, location) | errors]}
    end
  end

  defp finalize(document, []), do: {:ok, document}

  defp finalize(_document, errors) do
    {:error, Enum.sort_by(errors, fn error -> error.location.start_offset end)}
  end
end
