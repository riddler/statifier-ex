defmodule Statifier.Lowering do
  @moduledoc """
  The second arrow of the parser pipeline: a generic
  `%Statifier.Parser.DOM.Element{}` tree in, a typed `%Statifier.Document{}`
  tree out (`docs/architecture.md`, "Parser: DOM first, then lowering").

  ## The accumulator contract

  `lower/1` performs one traversal. Every builder in
  `Statifier.Lowering.Builders` lowers its children first via
  `walk_children/2`, appending each child's errors to its own in document
  order; `lower/1` sorts the whole accumulated list by
  `location.start_offset` before returning, so the report reads in document
  order regardless of the order a parent happened to emit its own error
  relative to its children's.

  A builder that cannot place or build something still returns the best
  partial result it can (or nothing, when it cannot build one at all) so the
  walk keeps going and later errors are still found - but that partial tree
  is never handed back to the caller. `lower/1` returns `{:ok, document}`
  only when the accumulated error list is empty; any non-empty list means
  `{:error, errors}`, full stop, regardless of how much of the tree built
  successfully. Handing back a document that lowering itself does not trust
  would just move the "is this actually usable" question onto every caller.

  ## Dispatch is context-free

  The dispatch map's keys are exactly the supported element names; no
  `build_*` function in `Builders` takes a parent element name as an
  argument. A builder does not know or care what its parent was - the
  parent, when it exists, is what decides whether the child's tagged
  result has anywhere to go (`Builders.place/3`). The
  parent's own element name is known only to itself, and is used solely to
  word a `{:misplaced_element, name, parent_name}` error about one of *its
  own* children - it is never handed down to a child builder.

  ## Relaxed input

  Both dispatch sites (`lower/1`, `walk_child/4`) accept an element with no
  namespace as SCXML's own vocabulary, not only one resolved to the SCXML
  namespace. `Statifier.Lowering.Namespace.scxml_vocabulary?/1` is the
  mechanism and its moduledoc states the commitment; this is a pointer for
  the reader who starts here instead.
  """

  alias Statifier.Document
  alias Statifier.Lowering.Builders
  alias Statifier.Lowering.Error
  alias Statifier.Lowering.Namespace
  alias Statifier.Parser.DOM.Element
  alias Statifier.Parser.DOM.Text

  @dispatch %{
    "scxml" => &Builders.build_scxml/2,
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
  by element name.

  Returns `{:ok, document}` only when the whole walk accumulated no errors;
  any error at all, anywhere in the tree, produces `{:error, errors}` with
  the errors sorted into document order - never a partial document, even
  when most of the tree built successfully. An element outside the SCXML
  vocabulary (and not using the relaxed no-namespace fallback) is reported
  as `{:foreign_element, name, uri, location}`; a non-`<scxml>` root name is
  `{:unexpected_root, local_name, location}`.
  """
  @spec lower(root :: Element.t()) :: {:ok, Document.t()} | {:error, [Error.t()]}
  def lower(%Element{name: name, location: location} = root) do
    scope = Namespace.push(%{}, root)
    {uri, local_name} = Namespace.resolve(name, scope)

    if Namespace.scxml_vocabulary?(uri) do
      case Map.fetch(@dispatch, local_name) do
        {:ok, builder} ->
          {document, errors} = builder.(root, %{ns_scope: scope})
          finalize(%{document | namespace: uri}, errors)

        :error ->
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
