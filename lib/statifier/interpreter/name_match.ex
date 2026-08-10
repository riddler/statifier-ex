defmodule Statifier.Interpreter.NameMatch do
  @moduledoc """
  Spec 3.13 event descriptor matching - Appendix D's `nameMatch`, under
  ADR-0002's predicate-naming amendment.

  A descriptor matches an event name iff the descriptor's tokens are a
  prefix of the event's tokens **on token boundaries**: the descriptor
  `["error"]` matches the event `error.execution` but not `errors.execution`
  - `errors` and `error` share a string prefix but not a token, and 3.13
  matches tokens, not characters.

  Normalization (Decision 4) folds the three special cases the spec
  describes into one prefix test:

  ```
  ["*"]            -> []            (bare * -> empty prefix -> matches all)
  ["foo", "*"]     -> ["foo"]       (foo.* matches foo AND foo.bar)
  ["foo", ""]      -> ["foo"]       (trailing dot, spec-equivalent to foo)
  ["error"]        -> ["error"]     (matches error.execution, not errors.execution)
  ```

  A trailing `"*"` token or a trailing `""` token (produced by splitting a
  descriptor that ends in a literal `.`, e.g. `"foo."` splits to
  `["foo", ""]`) is dropped before the prefix test; a `*` that is **not**
  the last token (`"foo.*.bar"`) is left alone and matched literally - 3.13
  defines the wildcard only as a trailing element, so there is nothing to
  port for the interior case, and inventing a rule here would be a semantic
  deviation from the spec rather than a mechanical one.

  `Statifier.Machine.Transition.events` arrives already split into
  `[[String.t()]]` - one dot-split token list per whitespace-separated
  descriptor, done once at compile time
  (`Statifier.Machine.Transition` moduledoc). `name_match?/2` therefore
  takes pre-split token lists on both sides rather than the pseudocode's
  `nameMatch(descriptorList, eventName)` strings; `tokenize/1` is the other
  half of that split, applied to the event name **once per selection round**
  by `Statifier.Interpreter.Selection.select_transitions/2` rather than once
  per transition, which is a mechanical hoist and not a semantic change
  (Decision 4).

  A transition with `events == []` is eventless and is never handed to this
  matcher: `Statifier.Interpreter.Selection.select_transitions/2` considers
  only transitions with `events != []`, and
  `select_eventless_transitions/1` only those with `events == []` - the
  pseudocode's `t.event` / `!t.event` test, spelled for a pre-split list.
  """

  @doc """
  Whether any of `descriptors` matches the event whose name is
  `event_tokens`.

  `descriptors` is `Statifier.Machine.Transition.events` (or a slice of
  it): one dot-split token list per whitespace-separated descriptor in the
  transition's `event` attribute. Any single descriptor matching enables
  the transition - the pseudocode's "any match" rule for a multi-descriptor
  attribute.
  """
  @spec name_match?(descriptors :: [[String.t()]], event_tokens :: [String.t()]) :: boolean()
  def name_match?(descriptors, event_tokens) do
    Enum.any?(descriptors, &descriptor_match?(&1, event_tokens))
  end

  @spec descriptor_match?(descriptor :: [String.t()], event_tokens :: [String.t()]) :: boolean()
  defp descriptor_match?(descriptor, event_tokens) do
    normalized = normalize(descriptor)
    Enum.take(event_tokens, length(normalized)) == normalized
  end

  @spec normalize(descriptor :: [String.t()]) :: [String.t()]
  defp normalize(descriptor) do
    case List.last(descriptor) do
      "*" -> :lists.droplast(descriptor)
      "" -> :lists.droplast(descriptor)
      _last -> descriptor
    end
  end

  @doc "Splits an event name into the dot-separated tokens `name_match?/2` compares."
  @spec tokenize(name :: String.t()) :: [String.t()]
  def tokenize(name) do
    String.split(name, ".")
  end
end
