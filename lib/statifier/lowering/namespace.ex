defmodule Statifier.Lowering.Namespace do
  @moduledoc """
  Prefix scope resolution for `Statifier.Lowering`'s walk (Decision 8,
  `docs/plans/260807-st-l5k.4-lowers-dom-to-document.md` Phase 5).

  A scope is a plain map from a declared prefix (a `String.t()`, or the atom
  `:default` for a bare `xmlns="..."`) to the URI it was bound to. It is
  threaded down the walk as a value, never stored globally: `push/2` returns a
  *new* scope for the element's own subtree, folding in only that element's
  own `xmlns` / `xmlns:*` attributes on top of what it inherited. A
  declaration on one child is therefore invisible to its siblings and to its
  parent - scoping falls out of the threading itself, not out of any special
  cleanup step.
  """

  alias Statifier.Parser.DOM.Attribute
  alias Statifier.Parser.DOM.Element

  @scxml_namespace "http://www.w3.org/2005/07/scxml"

  @type scope :: %{optional(String.t() | :default) => String.t()}

  @doc """
  The SCXML namespace URI. Dispatch treats an element resolving to this URI,
  or to no namespace at all, as SCXML's own vocabulary (Decision 8).
  """
  @spec scxml_namespace() :: String.t()
  def scxml_namespace, do: @scxml_namespace

  @doc """
  Folds `element`'s own `xmlns` and `xmlns:*` attributes into `scope`,
  returning a new scope for `element`'s subtree. `scope` itself is never
  mutated - the caller keeps its own copy for siblings, which is what makes a
  declaration subtree-local.
  """
  @spec push(scope :: scope(), element :: Element.t()) :: scope()
  def push(scope, %Element{attributes: attributes}) when is_map(scope) do
    Enum.reduce(attributes, scope, &declare(&2, &1))
  end

  @spec declare(scope :: scope(), attribute :: Attribute.t()) :: scope()
  defp declare(scope, %Attribute{name: "xmlns", value: uri}), do: Map.put(scope, :default, uri)

  defp declare(scope, %Attribute{name: "xmlns:" <> prefix, value: uri}) when prefix != "" do
    Map.put(scope, prefix, uri)
  end

  defp declare(scope, %Attribute{}), do: scope

  @doc """
  Resolves `qualified_name` (an element's raw, possibly-prefixed name, exactly
  as `Statifier.Parser.DOM.Element.name` carries it) against `scope`, returning
  `{uri_or_nil, local_name}`.

  A name with no `:` resolves against the `:default` binding, which is `nil`
  when no bare `xmlns` is in scope - the lenient case Decision 8 asks for. A
  prefixed name resolves against its own prefix, which is likewise `nil` when
  the prefix was never declared; that document is malformed, but a prefixed
  local name still dispatches under the same leniency rather than lowering
  refusing to read it.
  """
  @spec resolve(qualified_name :: String.t(), scope :: scope()) :: {String.t() | nil, String.t()}
  def resolve(qualified_name, scope) when is_binary(qualified_name) and is_map(scope) do
    case String.split(qualified_name, ":", parts: 2) do
      [prefix, local] -> {Map.get(scope, prefix), local}
      [local] -> {Map.get(scope, :default), local}
    end
  end
end
