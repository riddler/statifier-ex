defmodule Statifier.Interpreter.NameMatchTest do
  use ExUnit.Case, async: true

  alias Statifier.Interpreter.NameMatch

  # sabotage: descriptor_match?/2 compares the taken prefix against the
  # reversed normalized descriptor -> red
  test "full-name match" do
    assert NameMatch.name_match?([["error", "execution"]], ["error", "execution"])
  end

  # sabotage: descriptor_match?/2 requires event_tokens == normalized (exact
  # length) instead of a prefix -> red
  test "boundary prefix match" do
    assert NameMatch.name_match?([["error"]], ["error", "execution"])
  end

  # sabotage: descriptor_match?/2 compares with String.starts_with?/2 on the
  # dot-joined strings instead of token boundaries -> red
  test "non-boundary NON-match" do
    refute NameMatch.name_match?([["error"]], ["errors", "execution"])
  end

  # sabotage: name_match?/2 requires strictly more event tokens than prefix
  # tokens (the v1 bug) -> red
  test "trailing .* matches both the bare prefix and a longer name" do
    assert NameMatch.name_match?([["foo", "*"]], ["foo"])
    assert NameMatch.name_match?([["foo", "*"]], ["foo", "bar"])
  end

  # sabotage: normalize/1 drops the trailing "" clause entirely, leaving a
  # trailing dot descriptor unnormalized -> red
  test "trailing dot behaves as the descriptor without it" do
    assert NameMatch.name_match?([["foo", ""]], ["foo"])
    assert NameMatch.name_match?([["foo", ""]], ["foo", "bar"])
  end

  # sabotage: normalize/1 only drops a trailing "*" or "" when the
  # descriptor has more than one token, leaving a bare ["*"] untouched -> red
  test "bare * matches every event, including a single-token name" do
    assert NameMatch.name_match?([["*"]], ["foo"])
    assert NameMatch.name_match?([["*"]], ["foo", "bar"])
  end

  # sabotage: name_match?/2 uses Enum.all?/2 over descriptors instead of
  # Enum.any?/2 (the second v1 regression - a bare * alongside a specific
  # descriptor stops matching) -> red
  test "multi-descriptor: any match enables" do
    assert NameMatch.name_match?([["foo"], ["*"]], ["bar"])
  end

  # sabotage: descriptor_match?/2 truncates both sides to the shorter length
  # before comparing, tolerating a descriptor longer than the event -> red
  test "a longer descriptor does not match a shorter event name" do
    refute NameMatch.name_match?([["foo", "bar"]], ["foo"])
  end

  # sabotage: tokenize/1 splits on "" instead of "." -> red
  test "tokenize/1 round-trips a dotted name and a single-token name" do
    assert NameMatch.tokenize("error.execution") == ["error", "execution"]
    assert NameMatch.tokenize("foo") == ["foo"]
  end
end
