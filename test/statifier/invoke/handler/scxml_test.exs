defmodule Statifier.Invoke.Handler.ScxmlTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Handler.Scxml

  # The plan context (`Statifier.Invoke.Handler.t:ctx/0`) - contents unread
  # by `Scxml`, which builds its instructions from `invoke` alone, but
  # supplied in full so a future reader can see the shape without chasing
  # the behaviour definition.
  @ctx %{session_id: "sess_test", invoke_types: nil, invoke_handlers: %{}}

  defp invoke(type) do
    %Invoke{
      invoke_id: "i1",
      type: type,
      state_index: 0,
      invoke_index: 0,
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  describe "start/2" do
    # sabotage: `start/2`'s returned instruction is changed from
    # `{:start_child, invoke, {:invoke, invoke}}` to `{:start_child, invoke,
    # invoke}` (dropping the `:invoke` effect-tag wrapper) -> the equality
    # assertion below reddens, since the third element no longer matches the
    # `{:invoke, %Invoke{}}` shape `Statifier.Session.Effects.plan_one/2`
    # built the original effect as. Reverted and confirmed green.
    test "for a static type (\"scxml\") returns the {:start_child, ...} instruction plan_invoke/2 used to produce directly" do
      inv = invoke("scxml")

      assert Scxml.start(inv, @ctx) == {:ok, [{:start_child, inv, {:invoke, inv}}]}
    end

    # sabotage: same mutation as above, applied to the same `start/2` body -
    # a typeexpr-resolved type reaches `start/2` as an already-resolved
    # string in `invoke.type`, identically to a static type, so the same
    # mutation reddens this assertion the same way. Reverted and confirmed
    # green.
    test "for a typeexpr-resolved type (the long scxml URI) returns the same shape" do
      inv = invoke("http://www.w3.org/TR/scxml/")

      assert Scxml.start(inv, @ctx) == {:ok, [{:start_child, inv, {:invoke, inv}}]}
    end

    # sabotage: same mutation as above - `type: nil` is the built-in set's
    # third member (`Statifier.Invoke.Types.registered?/2`'s own typedoc),
    # and `start/2` treats it identically to every other `type` value since
    # it never inspects `type` itself, only `invoke` as a whole. Reverted
    # and confirmed green.
    test "for type: nil returns the same shape" do
      inv = invoke(nil)

      assert Scxml.start(inv, @ctx) == {:ok, [{:start_child, inv, {:invoke, inv}}]}
    end
  end

  describe "cancel/2 and forward/3" do
    # sabotage: `cancel/2`'s returned instruction is changed from
    # `{:stop_child, invoke_id}` to `{:stop_child, "wrong"}`, hardcoding a
    # different id -> the equality assertion below reddens.
    test "cancel/2 returns {:stop_child, invoke_id}" do
      assert Scxml.cancel("i1", @ctx) == {:ok, [{:stop_child, "i1"}]}
    end

    # sabotage: `forward/3`'s returned instruction is changed from
    # `{:forward, invoke_id, event}` to `{:forward, invoke_id, %{event |
    # name: "wrong"}}`, mutating the forwarded event's name -> the equality
    # assertion below reddens, since 6.4.2 requires the forwarded copy to
    # carry the same field values as the original.
    test "forward/3 returns {:forward, invoke_id, event}" do
      event = Statifier.Event.external("go")

      assert Scxml.forward("i1", event, @ctx) == {:ok, [{:forward, "i1", event}]}
    end
  end
end
