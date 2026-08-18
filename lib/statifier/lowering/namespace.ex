defmodule Statifier.Lowering.Namespace do
  @moduledoc """
  Prefix scope resolution for `Statifier.Lowering`'s walk.

  A scope is a plain map from a declared prefix (a `String.t()`, or the atom
  `:default` for a bare `xmlns="..."`) to the URI it was bound to. It is
  threaded down the walk as a value, never stored globally: `push/2` returns a
  *new* scope for the element's own subtree, folding in only that element's
  own `xmlns` / `xmlns:*` attributes on top of what it inherited. A
  declaration on one child is therefore invisible to its siblings and to its
  parent - scoping falls out of the threading itself, not out of any special
  cleanup step.
  """

  alias Statifier.Parser.DOM.{Attribute, Element}

  @scxml_namespace "http://www.w3.org/2005/07/scxml"

  @type scope :: %{optional(String.t() | :default) => String.t()}

  @doc """
  The SCXML namespace URI. Dispatch treats an element resolving to this URI,
  or to no namespace at all, as SCXML's own vocabulary.
  """
  @spec scxml_namespace() :: String.t()
  def scxml_namespace, do: @scxml_namespace

  @doc """
  Whether `uri` dispatches as SCXML's own vocabulary: the SCXML namespace
  itself, or **no namespace at all**.

  The `nil` case is the relaxed-parsing commitment. A fragment that
  declares no `xmlns` - `<scxml><state id="a"/></scxml>` - lowers exactly as
  its fully-declared twin does. v1 achieved this by inserting `xmlns=` into
  the source string before parsing; v2 relaxes this check instead, so spans
  still slice out of the binary the caller passed (`Location.slice/2`) with
  no translation step. Tightening this predicate would break a documented
  capability, not merely a fixture.

  Reporting an absent or non-SCXML `xmlns` is the validator's job, which has
  `Document.xmlns` and its `attribute_locations` entry to report from.
  """
  @spec scxml_vocabulary?(uri :: String.t() | nil) :: boolean()
  def scxml_vocabulary?(uri), do: uri in [nil, @scxml_namespace]

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
  when no bare `xmlns` is in scope - the same lenient reading applies here
  as to an unprefixed root. A prefixed name resolves against its own prefix,
  which is likewise `nil` when the prefix was never declared; that document
  is malformed, but a prefixed local name still dispatches under the same
  leniency rather than lowering refusing to read it.
  """
  @spec resolve(qualified_name :: String.t(), scope :: scope()) :: {String.t() | nil, String.t()}
  def resolve(qualified_name, scope) when is_binary(qualified_name) and is_map(scope) do
    case String.split(qualified_name, ":", parts: 2) do
      [prefix, local] -> {Map.get(scope, prefix), local}
      [local] -> {Map.get(scope, :default), local}
    end
  end
end
