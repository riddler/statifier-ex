defmodule Statifier.EventDataTest do
  use ExUnit.Case, async: true

  alias Statifier.EventData

  describe "coerce/1 - {:value, v}" do
    # sabotage: `coerce({:value, value})`'s clause is changed to
    # `from_text(value)` (routing an already-evaluated value back through
    # the text ladder) -> the integer stays 42 (harmless here) but the
    # string case below reddens, since `"21"` would come back as the
    # integer `21` instead of staying the string `"21"`.
    test "rides through unchanged, including a string that would parse as a number" do
      assert EventData.coerce({:value, 42}) == 42
      assert EventData.coerce({:value, "21"}) == "21"
      assert EventData.coerce({:value, nil}) == nil
      assert EventData.coerce({:value, %{"a" => 1}}) == %{"a" => 1}
    end
  end

  describe "coerce/1 - {:text, t}" do
    # sabotage: `from_text/1`'s successful-parse branch is changed to
    # return `trimmed` instead of `value` -> this reddens, since "21" would
    # stay the string "21" instead of becoming the integer 21.
    test "a literal-parseable numeral becomes the number" do
      assert EventData.coerce({:text, "21"}) == 21
    end

    # sabotage: `from_text/1`'s `with` clause's `else` branch is deleted, so
    # a `Predicator.compile_with_spans/1` or `Predicator.evaluate/2` failure
    # propagates instead of falling through to `space_normalize/1` -> this
    # reddens, since "foo" (an unbound identifier under the empty context)
    # would raise a `MatchError` instead of yielding the string "foo".
    test "an unparseable-as-literal identifier falls through to the string" do
      assert EventData.coerce({:text, "foo"}) == "foo"
    end

    # sabotage: `from_text/1`'s success branch is changed to
    # `if is_boolean(value), do: trimmed, else: value` (keep the raw text
    # for a boolean parse instead of the parsed value) -> this reddens,
    # since "true" would stay the string "true" instead of becoming `true`.
    test "a literal-parseable boolean becomes the boolean" do
      assert EventData.coerce({:text, "true"}) == true
    end

    # sabotage: `space_normalize/1`'s `String.replace(trimmed, ~r/\s+/, "
    # ")` call is changed to `trimmed` (skip normalization) -> this
    # reddens, since "a   b" (from a source with a leading/trailing run and
    # an internal run of spaces) would keep its extra internal whitespace
    # instead of collapsing to a single space.
    test "whitespace is trimmed and internal runs collapsed" do
      assert EventData.coerce({:text, "  a   b  "}) == "a b"
    end

    # sabotage: `from_text/1`'s `"" -> :undefined` clause is changed to `"" ->
    # ""` -> this reddens, since whitespace-only text would come back as
    # the empty string instead of `:undefined`.
    test "whitespace-only text is undefined, not the empty string" do
      assert EventData.coerce({:text, "  "}) == :undefined
    end
  end

  describe "coerce/1 - {:params, pairs}" do
    # sabotage: `from_params/1`'s `[] -> :undefined` clause is changed to
    # `[] -> %{}` -> this reddens, since an empty param list would produce
    # `%{}` instead of `:undefined` (conf:emptyEventData requires
    # `undefined`, not an empty map).
    test "an empty list is undefined, not an empty map" do
      assert EventData.coerce({:params, []}) == :undefined
    end

    # sabotage: `from_params/1`'s `Enum.reduce/3` is changed to
    # `Enum.reduce(Enum.reverse(pairs), %{}, ...)` -> this reddens, since a
    # duplicate name's *first* occurrence would win instead of its last.
    test "pairs fold in document order into a map, duplicate keys last-wins" do
      pairs = [{"a", 1}, {"b", 2}, {"a", 3}]

      assert EventData.coerce({:params, pairs}) == %{"a" => 3, "b" => 2}
    end
  end

  describe "coerce/1 - undefined versus null, side by side" do
    # sabotage: `from_params/1`'s `[] -> :undefined` clause is changed to
    # `[] -> nil` -> this reddens, since an empty param list ("no data")
    # would come back indistinguishable from an explicit null value.
    test "an empty rung is undefined; a genuinely null value stays nil" do
      assert EventData.coerce({:params, []}) == :undefined
      assert EventData.coerce({:value, nil}) == nil
    end
  end
end
