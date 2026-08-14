defmodule Statifier.EventData do
  @moduledoc """
  `docs/datamodel.md`'s standing commitment discharged: one function, with
  defined rules, that normalizes a value into `_event.data` per spec
  B.2.8.1. `<param>` and `<content>` (under `<donedata>`) call it here;
  `namelist`, `<send>`, and `<invoke>` extend it rather than reinventing it
  when they land (`docs/plans/260813-st-af3.7-log-donedata-param-event-data-coercion.md`
  Decision 2).

  B.2.8.1's own ladder, and which rungs this function implements:

  > If the value is not already in the indicated format, the Processor
  > SHOULD convert it to the indicated format. ... If the data consists
  > unambiguously of key/value pairs (e.g., the params of a <send> element,
  > or the fields of an HTML form), the Processor MUST convert this data to
  > a set of key/value pairs, ... If the Processor supports JSON [RFC4627],
  > and the data is a well-formed JSON expression, the Processor MUST parse
  > it into a data structure ... If the data is a well-formed external
  > parsed entity, and the Processor supports XML, the Processor MUST parse
  > it into a DOM document ... Otherwise, the Processor MUST treat the data
  > as a space-normalized string.

  | B.2.8.1 rung | Implemented here? |
  |---|---|
  | Indicated format (SHOULD) | No - no content-type channel exists yet. |
  | Key-value pairs (MUST) | Yes - the `{:params, pairs}` arm. |
  | JSON (MUST, if supported) | Substituted by a predicator literal-parse rung: this engine's value space is predicator's (ADR-0004), not ECMAScript's/JSON's, so the same ground (numbers, booleans, strings, lists, maps) is covered without a JSON dependency. |
  | XML DOM (MUST, if interpretable as XML) | No - `Statifier.Document.Content`'s moduledoc already rejects carrying a DOM subtree in a `Document` struct. |
  | Space-normalized string literal (MUST) | Yes - the fallback. |

  **Duplicate `<param>` keys.** B.2.8.1: "In the case of duplicate keys, the
  behavior is platform-specific." This project's call: fold in document
  order with `Map.put` semantics, so the last occurrence of a duplicate
  name wins - the same resolution an ECMAScript object literal gives
  duplicate properties, and what a left-to-right fold produces with no
  extra machinery.
  """

  @typedoc """
  The three shapes a caller hands to `coerce/1`: an already-evaluated
  value (never re-interpreted as text), raw `<content>` text (parsed or
  space-normalized), or a `<param>` name/value list (folded into a map).
  """
  @type input ::
          {:value, term()}
          | {:text, String.t()}
          | {:params, [{String.t(), term()}]}

  @doc """
  Normalizes `input` into an `_event.data` value per B.2.8.1, as detailed
  in the moduledoc above.
  """
  @spec coerce(input :: input()) :: term() | nil
  def coerce({:value, value}), do: value
  def coerce({:text, text}), do: from_text(text)
  def coerce({:params, pairs}), do: from_params(pairs)

  # B.2.8.1's bottom two rungs. The predicator-literal rung stands in for
  # the JSON rung (moduledoc table above): the clause is conditional on
  # JSON support, and this engine's value space is predicator's (ADR-0004).
  # The empty, on_unbound: :error context is the same guard
  # `Statifier.Compiler.Expressions.inline_value/1` documents - `foo`
  # compiles to an identifier load that errors against a context holding
  # nothing, so it falls through to the string literal instead of silently
  # becoming a datamodel read.
  @spec from_text(text :: String.t()) :: term() | nil
  defp from_text(text) do
    case String.trim(text) do
      "" ->
        nil

      trimmed ->
        empty_context = Predicator.Context.new(%{}, on_unbound: :error)

        with {:ok, %Predicator.Compiled{} = compiled} <- Predicator.compile_with_spans(trimmed),
             {:ok, value} <- Predicator.evaluate(compiled, empty_context) do
          value
        else
          _failure -> space_normalize(trimmed)
        end
    end
  end

  # B.2.8.1: "the Processor MUST treat the content as a space-normalized
  # string literal" - trim, then collapse internal whitespace runs to a
  # single space.
  @spec space_normalize(trimmed :: String.t()) :: String.t()
  defp space_normalize(trimmed), do: String.replace(trimmed, ~r/\s+/, " ")

  # B.2.8.1's key-value rung. Document order, last duplicate key wins (see
  # moduledoc). An empty result is `nil`, not `%{}` - conf:emptyEventData
  # (test343/488/528) requires absent event data to be `undefined`.
  @spec from_params(pairs :: [{String.t(), term()}]) :: %{optional(String.t()) => term()} | nil
  defp from_params([]), do: nil

  defp from_params(pairs) do
    Enum.reduce(pairs, %{}, fn {name, value}, acc -> Map.put(acc, name, value) end)
  end
end
