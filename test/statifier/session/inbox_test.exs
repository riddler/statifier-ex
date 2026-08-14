defmodule Statifier.Session.InboxTest do
  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Session.Inbox

  defp event(name), do: Event.external(name)

  describe "next/1 and enqueue_event/2, enqueue_cancel/1" do
    # sabotage: `next/1` uses `:queue.out_r/1` (back of the queue) instead of
    # `:queue.out/1` -> the assertion on dequeue order reddens
    test "dequeues events and cancel markers in FIFO order" do
      inbox =
        Inbox.new()
        |> Inbox.enqueue_event(event("a"))
        |> Inbox.enqueue_cancel()
        |> Inbox.enqueue_event(event("b"))

      assert {:ok, {:event, %Event{name: "a"}}, inbox} = Inbox.next(inbox)
      assert {:ok, :cancel, inbox} = Inbox.next(inbox)
      assert {:ok, {:event, %Event{name: "b"}}, inbox} = Inbox.next(inbox)
      assert Inbox.next(inbox) == :empty
    end

    # sabotage: `next/1` returns `{:ok, nil, inbox}` instead of `:empty` when
    # the queue has nothing waiting -> the empty-inbox assertion reddens
    test "next/1 on an empty inbox is :empty" do
      assert Inbox.next(Inbox.new()) == :empty
    end
  end

  describe "cancel_event?/1" do
    # sabotage: `cancel_event?/1` matches `{:event, _}` instead of `:cancel`
    # for its true clause -> both assertions reddens
    test "is true only for the cancel marker" do
      assert Inbox.cancel_event?(:cancel)
      refute Inbox.cancel_event?({:event, event("a")})
    end
  end

  describe "pending_events/1" do
    # sabotage: `pending_events/1` keeps `:cancel` entries in the returned
    # list instead of dropping them -> the length assertion reddens
    test "returns only the waiting events, cancel markers dropped, in order" do
      inbox =
        Inbox.new()
        |> Inbox.enqueue_event(event("a"))
        |> Inbox.enqueue_cancel()
        |> Inbox.enqueue_event(event("b"))

      assert [%Event{name: "a"}, %Event{name: "b"}] = Inbox.pending_events(inbox)
    end
  end

  describe "size/1" do
    # sabotage: `size/1` returns `0` unconditionally instead of
    # `:queue.len/1` on the inbox's `:queue` -> the nonzero-size assertion
    # reddens
    test "counts every waiting entry, events and cancel markers both" do
      inbox =
        Inbox.new()
        |> Inbox.enqueue_event(event("a"))
        |> Inbox.enqueue_cancel()

      assert Inbox.size(inbox) == 2
      assert Inbox.size(Inbox.new()) == 0
    end
  end
end
