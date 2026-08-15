defmodule Statifier.DurationTest do
  use ExUnit.Case, async: true

  alias Statifier.Duration

  describe "to_ms/1 - strings" do
    # sabotage: `to_ms/1`'s binary clause is changed to call
    # `PredicatorDuration.parse(value)` directly, skipping
    # `normalize_leading_dot/1` -> this test is unaffected (no leading dot),
    # but the ".5s" test below reddens because ".5s" is not on its own a
    # string `Predicator.Duration.parse/1` accepts.
    test "a plain seconds string resolves to milliseconds" do
      assert Duration.to_ms("2s") == {:ok, 2_000}
    end

    # sabotage: `to_ms/1`'s success branch is changed to
    # `{:ok, PredicatorDuration.to_seconds(duration)}` (the wrong
    # converter) -> this reddens, since 1500ms would come back as 1
    # (1.5 seconds truncated to whole seconds).
    test "a fractional seconds string resolves to milliseconds" do
      assert Duration.to_ms("1.5s") == {:ok, 1_500}
    end

    # sabotage: `normalize_leading_dot/1`'s first clause pattern is changed
    # from `"." <> rest` to `"," <> rest` -> this reddens, since the leading
    # dot in ".5s" would no longer be rewritten to "0.5s" and
    # `Predicator.Duration.parse/1` would reject the raw ".5s" string,
    # turning the {:ok, 500} result into an {:error, _}.
    test "the schema's bare leading-dot spelling resolves the same as the zero-prefixed form" do
      assert Duration.to_ms(".5s") == {:ok, 500}
    end

    # sabotage: `to_ms/1`'s error branch is changed to
    # `{:error, :invalid_delay}` (dropping the offending value from the
    # reason) -> this reddens, since the assertion pattern-matches the
    # original string back out of the reason tuple.
    test "a sub-millisecond fractional remainder is rejected" do
      assert Duration.to_ms("0.5ms") == {:error, {:invalid_delay, "0.5ms"}}
    end

    # sabotage: `to_ms/1`'s binary clause's `case` is changed to ignore the
    # `:error` arm and always return `{:ok, PredicatorDuration.to_milliseconds(nil)}`
    # -> this reddens (with a crash, which still proves the guard mattered)
    # instead of the clean {:error, _} junk input demands.
    test "junk input is rejected" do
      assert {:error, {:invalid_delay, "not a duration"}} = Duration.to_ms("not a duration")
    end

    # sabotage: `Statifier.Duration`'s moduledoc claim that predicator's
    # unit set is a superset is not itself code, so the mutation here is on
    # `normalize_leading_dot/1`'s pass-through clause: change
    # `def normalize_leading_dot(value), do: value` to
    # `def normalize_leading_dot(_value), do: "1s"` -> this reddens, since
    # "1h" would resolve to 1000 (one second) instead of 3_600_000.
    test "a superset unit outside the SCXML schema's five still resolves" do
      assert Duration.to_ms("1h") == {:ok, 3_600_000}
    end
  end

  describe "to_ms/1 - native predicator duration values" do
    # sabotage: `to_ms/1`'s map clause is changed to
    # `{:ok, PredicatorDuration.to_seconds(duration)}` -> this reddens,
    # since 1500 (milliseconds) would come back as 1 (whole seconds).
    test "a native duration value straight off delayexpr needs no parse" do
      duration = Predicator.Duration.new(seconds: 1, milliseconds: 500)

      assert Duration.to_ms(duration) == {:ok, 1_500}
    end
  end

  describe "normalize_leading_dot/1" do
    # sabotage: the pass-through clause's argument pattern is changed from
    # `def normalize_leading_dot(value), do: value` to
    # `def normalize_leading_dot(_value), do: ""` -> this reddens, since
    # "1.5s" would come back as "" instead of unchanged.
    test "a string with no leading dot passes through unchanged" do
      assert Duration.normalize_leading_dot("1.5s") == "1.5s"
    end

    # sabotage: the leading-dot clause's replacement is changed from
    # `"0." <> rest` to `"1." <> rest` -> this reddens, since ".5s" would
    # normalize to "1.5s" instead of "0.5s".
    test "a leading dot is rewritten to a zero-prefixed dot" do
      assert Duration.normalize_leading_dot(".5s") == "0.5s"
    end
  end
end
