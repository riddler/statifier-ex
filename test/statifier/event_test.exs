defmodule Statifier.EventTest do
  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Event.Cause

  @cause Cause.new({:content, 4, {:transition, 7}}, 2, 3, 1)

  describe "external/2" do
    # sabotage: `Event.external/2` stamps `type: :internal` instead of
    # `type: :external`, and separately stamps a non-nil `cause` -> this
    # pattern match reddens on either mutation.
    test "stamps type: :external with cause always nil" do
      assert %Event{type: :external, cause: nil} = Event.external("go")
    end

    # sabotage: `Event.external/2` defaults `data` to `nil` instead of
    # `:undefined` -> this assertion reddens because `:undefined` ("no
    # data") is distinguishable from `nil` ("data, present, null") and from
    # an empty map.
    test "data defaults to :undefined, distinct from nil and from %{}" do
      event = Event.external("go")

      assert event.data == :undefined
      refute event.data == nil
      refute event.data == %{}
    end

    # sabotage: `Event.external/2` ignores the `:data` option and always
    # stores `:undefined` -> this assertion reddens.
    test "data option is carried through" do
      assert Event.external("go", data: %{value: 1}).data == %{value: 1}
    end

    # sabotage: `Event.external/2` reads `Keyword.get(opts, :data,
    # :undefined)` is changed to `Keyword.get(opts, :data)` (default `nil`)
    # -> the first assertion reddens, since absent `data` would come back
    # `nil` instead of `:undefined`; the second assertion, which passes
    # `data: nil` explicitly, stays green either way and pins that an
    # explicit null payload is still distinguishable from an absent one -
    # open question 2's pin (ADR-0037).
    test "absent data is :undefined; an explicit nil payload stays nil" do
      assert Event.external("go").data == :undefined
      assert Event.external("go", data: nil).data == nil
    end
  end

  describe "internal/3" do
    # sabotage: `Event.internal/3` stamps `type: :external` instead of
    # `type: :internal` -> this assertion reddens.
    test "stamps type: :internal" do
      assert %Event{type: :internal} = Event.internal("done.state.a", @cause)
    end

    # sabotage: `Event.internal/3` drops the given `cause` and stores `nil`
    # instead -> this assertion reddens.
    test "carries the given cause through unchanged" do
      assert Event.internal("done.state.a", @cause).cause == @cause
    end

    # sabotage: `Event.internal/3` ignores the `:data` option and always
    # stores the `:undefined` default -> this assertion reddens.
    test "data option is carried through" do
      assert Event.internal("done.state.a", @cause, data: %{value: 1}).data == %{value: 1}
    end

    # sabotage: `Event.internal/3` ignores the `:sendid` option and always
    # stores `nil` -> this assertion reddens. Phase 4 is the first caller
    # that passes `:sendid` (for `<send target="#_internal">`), and a
    # dropped keyword here raises nothing, so this direct constructor test
    # is the only thing that would have caught it.
    test "sendid option is carried through" do
      assert Event.internal("done.state.a", @cause, sendid: "send1").sendid == "send1"
    end
  end

  describe "platform/3" do
    # sabotage: `Event.platform/3` stamps `type: :internal` instead of
    # `type: :platform` -> this assertion reddens, since :platform is
    # provenance-only and must stay distinguishable from :internal even
    # though both ride the same queue.
    test "stamps type: :platform" do
      assert %Event{type: :platform} = Event.platform("error.execution", @cause)
    end

    # sabotage: `Event.platform/3` drops the given `cause` and stores `nil`
    # instead -> this assertion reddens.
    test "carries the given cause through unchanged" do
      assert Event.platform("error.execution", @cause).cause == @cause
    end

    # sabotage: `Event.platform/3` ignores the `:data` option and always
    # stores the `:undefined` default -> this assertion reddens.
    test "data option is carried through" do
      assert Event.platform("error.execution", @cause, data: %{value: 1}).data == %{value: 1}
    end
  end
end
