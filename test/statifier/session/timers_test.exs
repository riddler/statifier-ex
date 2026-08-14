defmodule Statifier.Session.TimersTest do
  use ExUnit.Case, async: true

  alias Statifier.Session.Timers

  describe "put/3 and take/2" do
    # sabotage: `put/3` overwrites `send_id`'s list with `[ref]` instead of
    # appending -> the two-refs-under-one-id assertion reddens
    test "two refs scheduled under one send id are both returned, in scheduling order" do
      ref1 = make_ref()
      ref2 = make_ref()

      timers =
        Timers.new()
        |> Timers.put("s1", ref1)
        |> Timers.put("s1", ref2)

      assert {[^ref1, ^ref2], timers} = Timers.take(timers, "s1")
      assert Timers.count(timers) == 0
    end

    # sabotage: `take/2`'s unknown-id branch clears the whole `live` set
    # instead of returning the table unchanged -> the pinned-`timers`
    # equality assertion reddens
    test "take/2 on an unknown id is a no-op" do
      ref = make_ref()
      timers = Timers.put(Timers.new(), "s1", ref)

      assert {[], ^timers} = Timers.take(timers, "unknown")
      assert Timers.count(timers) == 1
    end
  end

  describe "put/3 with a nil send id" do
    # sabotage: `take/2`'s unknown-id branch clears the whole `live` set
    # instead of returning the table unchanged -> the post-take `refs/1`
    # assertion reddens, since the nil-id ref it should still hold is gone
    test "is tracked in refs/1 but reachable by no take/2" do
      ref = make_ref()
      timers = Timers.put(Timers.new(), nil, ref)

      assert Timers.refs(timers) == [ref]
      assert {[], timers} = Timers.take(timers, "s1")
      assert Timers.refs(timers) == [ref]
    end
  end

  describe "forget/2" do
    # sabotage: `forget/2` removes the ref from `live` but leaves it in its
    # `send_id` list -> the post-forget `take/2` assertion reddens
    test "removes a fired ref from both the live set and its send id's list" do
      ref1 = make_ref()
      ref2 = make_ref()

      timers =
        Timers.new()
        |> Timers.put("s1", ref1)
        |> Timers.put("s1", ref2)
        |> Timers.forget(ref1)

      assert Timers.count(timers) == 1
      assert {[^ref2], timers} = Timers.take(timers, "s1")
      assert Timers.count(timers) == 0
    end

    # sabotage: `forget/2` raises on a ref it has never seen instead of
    # returning the table unchanged -> this assertion reddens
    test "forgetting an unknown ref is a no-op" do
      timers = Timers.new()
      assert Timers.forget(timers, make_ref()) == timers
    end
  end

  describe "refs/1 and count/1" do
    # sabotage: `refs/1` returns only the ids' refs and drops the nil-id
    # ones -> the length assertion reddens
    test "refs/1 returns every live reference, nil-id sends included" do
      ref1 = make_ref()
      ref2 = make_ref()

      timers =
        Timers.new()
        |> Timers.put("s1", ref1)
        |> Timers.put(nil, ref2)

      assert Enum.sort(Timers.refs(timers)) == Enum.sort([ref1, ref2])
      assert Timers.count(timers) == 2
    end
  end
end
