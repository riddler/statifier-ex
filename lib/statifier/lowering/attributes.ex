defmodule Statifier.Lowering.Attributes do
  @moduledoc """
  The four attribute operations every builder in `Statifier.Lowering.Builders`
  needs: read a raw value, split a whitespace-separated value into a list,
  map a value onto a known atom with a default, and record a value span into
  `attribute_locations`.

  The `attribute_locations` rule lives here in one place
  (`lib/statifier/document.ex:22-44`): a key is added **only** when the
  attribute was written in the source **and** its `value_location` is
  non-nil. A written attribute whose `value_location` is `nil` (the
  handler's short-scan tolerance, `lib/statifier/parser/handler.ex:162-175`)
  still lowers its value - it is only the span that is absent.
  """

  alias Statifier.Document
  alias Statifier.Parser.DOM
  alias Statifier.Parser.DOM.Attribute
  alias Statifier.Parser.DOM.Element
  alias Statifier.Parser.Location

  @doc """
  The raw, entity-expanded value of `element`'s `name` attribute, or `nil`
  when the attribute was not written.
  """
  @spec value(element :: Element.t(), name :: binary()) :: String.t() | nil
  def value(%Element{} = element, name) when is_binary(name) do
    case DOM.attribute(element, name) do
      nil -> nil
      %Attribute{value: value} -> value
    end
  end

  @doc """
  `element`'s `name` attribute, whitespace-split into a list.

  An absent attribute becomes `[]`, and so does one written as `""` - the
  two are told apart, when it matters, by `attribute_locations`, never by
  the list itself (Decision 6).
  """
  @spec list(element :: Element.t(), name :: binary()) :: [String.t()]
  def list(%Element{} = element, name) when is_binary(name) do
    element
    |> value(name)
    |> split()
  end

  @spec split(raw :: String.t() | nil) :: [String.t()]
  defp split(nil), do: []
  defp split(raw) when is_binary(raw), do: String.split(raw)

  @doc """
  `element`'s `name` attribute mapped through `mapping` onto a known atom,
  or `default` when the attribute is absent or its value is not a key of
  `mapping`.

  An out-of-range value (`mapping` misses it) still lowers to `default`
  rather than erroring - an enumerated value outside its range is a
  semantic check, st-l5k.5's shape, not lowering's (Residual Note 2).
  """
  @spec atom(
          element :: Element.t(),
          name :: binary(),
          mapping :: %{optional(String.t()) => atom()},
          default :: atom()
        ) :: atom()
  def atom(%Element{} = element, name, mapping, default)
      when is_binary(name) and is_map(mapping) and is_atom(default) do
    case value(element, name) do
      nil -> default
      raw -> Map.get(mapping, raw, default)
    end
  end

  @doc """
  Adds `key => value_location` to `locations` when `element`'s `name`
  attribute was written and carries a non-nil `value_location`; returns
  `locations` unchanged otherwise.
  """
  @spec put_location(
          locations :: Document.attribute_locations(),
          key :: atom(),
          element :: Element.t(),
          name :: binary()
        ) :: Document.attribute_locations()
  def put_location(locations, key, %Element{} = element, name)
      when is_map(locations) and is_atom(key) and is_binary(name) do
    case DOM.attribute(element, name) do
      nil ->
        locations

      %Attribute{value_location: nil} ->
        locations

      %Attribute{value_location: %Location{} = value_location} ->
        Map.put(locations, key, value_location)
    end
  end
end
