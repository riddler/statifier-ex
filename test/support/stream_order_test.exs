defmodule Statifier.StreamOrderTest do
  use ExUnit.Case, async: true

  alias Statifier.StreamOrder

  # sabotage: n/a - this test asserts test/support/stream_order.ex's own
  # harness behavior (Gap 2 of ADR-0045's post-implementation review), not
  # lib/ behavior. `counters/1`'s new clause is exercised directly through
  # `assert_monotone/1`'s public surface below. Verified anyway: with the
  # new `{:effect, {tag, %{macrostep: macrostep} = payload}}` flunk clause
  # removed (reverting to the old `defp counters(_message), do: nil`
  # fallback catching this case), this test reddened with "Expected
  # exception ExUnit.AssertionError but nothing was raised". Reverted and
  # confirmed green.
  test "assert_monotone/1 flunks on an effect that carries macrostep but no round" do
    stream = [
      {:effect, {:send, %{macrostep: 1, microstep: 0}}}
    ]

    assert_raise ExUnit.AssertionError, ~r/:send effect at macrostep 1 carries no `round`/, fn ->
      StreamOrder.assert_monotone(stream)
    end
  end
end
