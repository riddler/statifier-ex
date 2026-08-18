defmodule Statifier.Parser.DOM do
  @moduledoc """
  The generic document tree `Statifier.Parser.parse/1` produces, and the three
  accessors every lowering builder would otherwise re-implement.

  A tree is `Statifier.Parser.DOM.Element` structs whose `children` interleave
  further elements with `Statifier.Parser.DOM.Text` runs in document order,
  each carrying a `Statifier.Parser.Location` span.

  The tree is deliberately unvalidated: unknown names, duplicate attributes,
  missing namespace declarations, and structurally nonsensical documents all
  parse successfully. The DOM reports what was written and lets the validator
  object.
  """

  alias Statifier.Parser.DOM.{Attribute, Element, Text}

  @doc """
  `element`'s children, filtered to elements.

  The whitespace filter for readers that want structure rather than markup:
  text runs between child elements are kept in the tree (the parser cannot
  know which of them are significant without knowing the vocabulary), and
  this is where a caller drops them.
  """
  @spec elements(element :: Element.t()) :: [Element.t()]
  def elements(%Element{children: children}) do
    Enum.filter(children, &match?(%Element{}, &1))
  end

  @doc """
  The first attribute of `element` named `name`, or `nil`.

  First, not only: duplicates are preserved in `attributes`, so a caller that
  wants to report one has the whole list to look at.
  """
  @spec attribute(element :: Element.t(), name :: binary()) :: Attribute.t() | nil
  def attribute(%Element{attributes: attributes}, name) when is_binary(name) do
    Enum.find(attributes, &(&1.name == name))
  end

  @doc """
  The concatenated decoded value of `element`'s direct text children.

  Child elements contribute nothing - this is the text of `element` itself,
  not of the subtree.
  """
  @spec text(element :: Element.t()) :: binary()
  def text(%Element{children: children}) do
    children
    |> Enum.filter(&match?(%Text{}, &1))
    |> Enum.map_join(& &1.value)
  end
end
