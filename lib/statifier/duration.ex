defmodule Statifier.Duration do
  @moduledoc """
  The one place this engine turns an SCXML duration designation - `<send
  delay>`'s attribute string, or a `delayexpr` result - into milliseconds.
  Wraps `Predicator.Duration` rather than reimplementing CSS2-style duration
  parsing.

  ## The unit set is a superset, delegated as-is

  The SCXML schema's `delay`/`delayexpr` pattern
  (`\\d*(\\.\\d+)?(ms|s|m|h|d)`) recognizes five units: `ms`, `s`, `m`
  (minutes), `h`, `d`. `Predicator.Duration.parse/1` recognizes eight:
  `y`, `mo`, `w`, `d`, `h`, `m`, `s`, `ms` - the same five plus `y`
  (years), `mo` (months), and `w` (weeks). Every unit the two sets share
  means the same thing in both (`m` is minutes, not months, in both), so
  predicator's set is a strict superset of the schema's, and this module
  delegates it whole rather than re-restricting parsing to the schema's five.
  A document that writes `delay="2w"` gets a working two-week delay; nothing
  here rejects it for being outside the schema pattern, since accepting more
  than the schema requires is never a conformance violation.

  ## The leading-dot concession

  The SCXML schema pattern above allows a bare leading dot - `".5s"` is a
  schema-valid `delay` value - but `Predicator.Duration.parse/1` does not:
  `parse(".5s")` is `:error` while `parse("1.5s")` is `{:ok, ...}` (verified
  against `deps/predicator/lib/predicator/duration.ex`'s own doctests).
  `normalize_leading_dot/1` is the one-line concession this schema pattern
  requires and predicator 8.0 deliberately does not make: it rewrites a
  leading `.` to `0.` before parsing, so `".5s"` and `"0.5s"` parse
  identically. This is the only rewrite this module performs; every other
  character reaches `Predicator.Duration.parse/1` untouched.
  """

  alias Predicator.Duration, as: PredicatorDuration
  alias Predicator.Types

  @typedoc "An SCXML duration designation: the raw `delay` string, or a native predicator duration value off `delayexpr`."
  @type value :: binary() | Types.duration()

  @doc """
  Resolves an SCXML duration designation to whole milliseconds.

  Accepts either a `delay`-style string (parsed via
  `Predicator.Duration.parse/1`, after `normalize_leading_dot/1`) or a
  native `Predicator.Duration` value straight off `delayexpr` (a computed
  duration such as `2s + backoff` needs no parsing - `delayexpr` already
  evaluated it to a duration map). A string that fails to parse - a bad
  unit, a sub-millisecond fractional remainder, or anything else
  `Predicator.Duration.parse/1` refuses - is `{:error, {:invalid_delay,
  value}}`; the caller is responsible for treating that as an argument
  failure (ADR-0036 governs `<send>`'s own case).
  """
  @spec to_ms(value :: value()) :: {:ok, non_neg_integer()} | {:error, term()}
  def to_ms(value) when is_binary(value) do
    case value |> normalize_leading_dot() |> PredicatorDuration.parse() do
      {:ok, duration} -> {:ok, PredicatorDuration.to_milliseconds(duration)}
      :error -> {:error, {:invalid_delay, value}}
    end
  end

  def to_ms(%{} = duration) do
    {:ok, PredicatorDuration.to_milliseconds(duration)}
  end

  @doc """
  Rewrites a leading `.` to `0.` (`".5s"` -> `"0.5s"`) - the concession the
  SCXML schema's `\\d*(\\.\\d+)?(ms|s|m|h|d)` pattern requires and
  `Predicator.Duration.parse/1` does not make on its own. A string with no
  leading dot passes through unchanged.
  """
  @spec normalize_leading_dot(value :: binary()) :: binary()
  def normalize_leading_dot("." <> rest), do: "0." <> rest
  def normalize_leading_dot(value), do: value
end
