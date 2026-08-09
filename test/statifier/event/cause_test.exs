defmodule Statifier.Event.CauseTest do
  use ExUnit.Case, async: true

  alias Statifier.Event.Cause

  describe "new/3" do
    # sabotage: `Cause.new/3` swaps the `macrostep`/`microstep` arguments
    # when building the struct -> the counters land in the wrong fields,
    # reddening this assertion.
    test "stamps a :transition origin with the given counters" do
      cause = Cause.new({:transition, 7}, 2, 3)

      assert %Cause{origin: {:transition, 7}, macrostep: 2, microstep: 3} = cause
    end

    # sabotage: `Cause.new/3` swaps the `macrostep`/`microstep` arguments
    # when building the struct -> the counters land in the wrong fields,
    # reddening this assertion (distinct counter values from the test above
    # so a swap cannot pass by coincidence).
    test "stamps a :content origin with the given counters" do
      cause = Cause.new({:content, 4}, 5, 1)

      assert %Cause{origin: {:content, 4}, macrostep: 5, microstep: 1} = cause
    end
  end
end
