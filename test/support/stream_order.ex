# sabotage: n/a - test plumbing, no lib/ behavior of its own
defmodule Statifier.StreamOrder do
  @moduledoc """
  Assertions over a drained `Statifier.Session` subscriber stream, for the
  ADR-0043 delivery-order contract.

  `round` lives only on the `Effect.Trace.*` payloads and on
  `Effect.BudgetExhausted` today (ADR-0043 decision 4 leaves stamping it
  onto the rest as follow-on work), so `assert_monotone/1` evaluates
  `(macrostep, round)` over exactly the effects that carry both, and
  `macrostep` alone over the effects that carry only it. That is the whole
  contract the shipped structs can express. `{:halted, _}` and
  `{:unroutable, _}` are envelopes and carry no counters at all - they are
  excluded from both checks (`assert_halted_last/1` covers the former
  separately).
  """

  import ExUnit.Assertions

  # drain/1  - receive every {:statifier, session_id, message}, envelope
  #            stripped, until a quiet window; preserves arrival order.
  # assert_monotone/1        - (macrostep, round) non-decreasing over the
  #                            counter-bearing sub-stream, and macrostep
  #                            non-decreasing over every counter-bearing
  #                            effect. Flunks naming the first inversion and
  #                            its two neighbours.
  # assert_stable_unique/1   - exactly one Trace.MacrostepStable per
  #                            (macrostep, round).
  # assert_halted_last/1     - a {:halted, _} message, if present, is the
  #                            final element.

  @doc """
  Drains every `{:statifier, session_id, message}` currently sitting in (or
  about to land in) the calling process's mailbox, envelope stripped, in
  arrival order, stopping once none has arrived for a short quiet window.
  Modelled on `test/statifier/replay_round_trip_test.exs`'s own
  `drain_stream/2`, which stays private there since `round_trip/3` already
  uses it.
  """
  @spec drain(session_id :: String.t(), acc :: [term()]) :: [term()]
  def drain(session_id, acc \\ []) do
    receive do
      {:statifier, ^session_id, message} -> drain(session_id, [message | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  @doc """
  Asserts `stream` arrives in non-decreasing `(macrostep, round)` order over
  the sub-stream that carries `round`, and non-decreasing `macrostep` order
  over every effect that carries a counter at all. Flunks naming the first
  inversion found and the two neighbouring entries it inverted against.
  """
  @spec assert_monotone(stream :: [term()]) :: :ok
  def assert_monotone(stream) do
    entries =
      stream
      |> Enum.map(&counters/1)
      |> Enum.with_index()
      |> Enum.reject(fn {counters, _index} -> is_nil(counters) end)

    check_non_decreasing(entries, fn {macrostep, _round} -> macrostep end, "macrostep")

    rounded = Enum.reject(entries, fn {{_macrostep, round}, _index} -> is_nil(round) end)

    check_non_decreasing(
      rounded,
      fn {macrostep, round} -> {macrostep, round} end,
      "(macrostep, round)"
    )

    :ok
  end

  @spec check_non_decreasing(
          entries :: [{{non_neg_integer(), non_neg_integer() | nil}, non_neg_integer()}],
          key_fun :: ({non_neg_integer(), non_neg_integer() | nil} -> term()),
          label :: String.t()
        ) :: :ok
  defp check_non_decreasing(entries, key_fun, label) do
    entries
    |> Enum.map(fn {counters, index} -> {key_fun.(counters), index} end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{prev_key, prev_index}, {key, index}] ->
      if key < prev_key do
        flunk("""
        #{label} inversion: stream index #{index} carries #{inspect(key)}, which is \
        less than stream index #{prev_index}'s #{inspect(prev_key)}.
        Neighbours: index #{prev_index} = #{inspect(prev_key)}, index #{index} = #{inspect(key)}
        """)
      end
    end)

    :ok
  end

  @spec counters(message :: term()) :: {non_neg_integer(), non_neg_integer() | nil} | nil
  defp counters({:effect, {_tag, %{macrostep: macrostep, round: round}}}), do: {macrostep, round}
  defp counters({:effect, {_tag, %{macrostep: macrostep}}}), do: {macrostep, nil}
  defp counters(_message), do: nil

  @doc """
  Asserts `stream` carries exactly one `Trace.MacrostepStable` per
  `(macrostep, round)` (ADR-0043 decision 3).
  """
  @spec assert_stable_unique(stream :: [term()]) :: :ok
  def assert_stable_unique(stream) do
    stream
    |> Enum.filter(&match?({:effect, {:trace, %Statifier.Effect.Trace.MacrostepStable{}}}, &1))
    |> Enum.map(fn {:effect, {:trace, %{macrostep: macrostep, round: round}}} ->
      {macrostep, round}
    end)
    |> Enum.frequencies()
    |> Enum.each(fn {key, count} ->
      if count != 1 do
        flunk(
          "expected exactly one Trace.MacrostepStable for (macrostep, round) = #{inspect(key)}, " <>
            "got #{count}"
        )
      end
    end)

    :ok
  end

  @doc """
  Asserts a `{:halted, _}` message, if present anywhere in `stream`, is the
  final element (ADR-0043 decision 2's end-of-stream promise).
  """
  @spec assert_halted_last(stream :: [term()]) :: :ok
  def assert_halted_last(stream) do
    case Enum.find_index(stream, &match?({:halted, _}, &1)) do
      nil ->
        :ok

      index ->
        assert index == length(stream) - 1,
               "expected {:halted, _} to be the last message (index #{length(stream) - 1}), " <>
                 "found it at index #{index} instead"

        :ok
    end
  end
end
