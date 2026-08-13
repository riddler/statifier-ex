defmodule Statifier.Event.CauseTest do
  use ExUnit.Case, async: true

  alias Statifier.Event.Cause

  describe "new/4" do
    # sabotage: `Cause.new/4` swaps the `macrostep`/`microstep`/`round`
    # arguments when building the struct -> the counters land in the wrong
    # fields, reddening this assertion.
    test "stamps a :content origin (owned by a transition) with the given counters" do
      cause = Cause.new({:content, 4, {:transition, 7}}, 2, 3, 1)

      assert %Cause{origin: {:content, 4, {:transition, 7}}, macrostep: 2, microstep: 3, round: 1} =
               cause
    end

    # sabotage: `Cause.new/4` swaps the `macrostep`/`microstep`/`round`
    # arguments when building the struct -> the counters land in the wrong
    # fields, reddening this assertion (distinct counter values from the test
    # above so a swap cannot pass by coincidence).
    test "stamps a :content origin (owned by an onentry block) with the given counters" do
      cause = Cause.new({:content, 4, {:onentry, 1, 0}}, 5, 1, 2)

      assert %Cause{origin: {:content, 4, {:onentry, 1, 0}}, macrostep: 5, microstep: 1, round: 2} =
               cause
    end

    # sabotage: `Cause.new/4` swaps the `macrostep`/`microstep`/`round`
    # arguments when building the struct -> the counters land in the wrong
    # fields, reddening this assertion (distinct counter values from the
    # tests above so a swap cannot pass by coincidence).
    test "stamps a :state origin with the given counters" do
      cause = Cause.new({:state, 9}, 6, 2, 4)

      assert %Cause{origin: {:state, 9}, macrostep: 6, microstep: 2, round: 4} = cause
    end

    # sabotage: `Cause.new/4` swaps the `macrostep`/`microstep`/`round`
    # arguments when building the struct -> the counters land in the wrong
    # fields, reddening this assertion (distinct counter values from the
    # tests above so a swap cannot pass by coincidence).
    test "stamps a :transition origin with the given counters" do
      cause = Cause.new({:transition, 7}, 4, 8, 3)

      assert %Cause{origin: {:transition, 7}, macrostep: 4, microstep: 8, round: 3} = cause
    end
  end
end
