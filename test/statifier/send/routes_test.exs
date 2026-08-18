defmodule Statifier.Send.RoutesTest do
  use ExUnit.Case, async: true

  alias Statifier.Send.Routes

  describe "new/2" do
    # sabotage: `new/1`'s `sessions:` default is changed from `MapSet.new()`
    # to `MapSet.new(["ghost"])` -> this reddens (default snapshot would
    # claim a session no caller declared)
    test "defaults to an empty snapshot" do
      routes = Routes.new()

      assert routes.sessions == MapSet.new()
      assert routes.parent? == false
      assert routes.invokes == MapSet.new()
    end

    # sabotage: `Keyword.get(opts, :sessions, MapSet.new())` is changed to
    # ignore the `:sessions` option (always `MapSet.new()`) -> this reddens
    test "accepts a list of session ids and normalizes them into a MapSet" do
      routes = Routes.new(sessions: ["sess_a", "sess_b"])

      assert routes.sessions == MapSet.new(["sess_a", "sess_b"])
    end

    # sabotage: `Keyword.get(opts, :parent?, false)` is changed to
    # `Keyword.get(opts, :parent?, false) |> Kernel.not()` (inverting
    # whatever was passed) -> this reddens
    test "accepts :parent?" do
      routes = Routes.new(parent?: true)

      assert routes.parent? == true
    end

    # sabotage: `Keyword.get(opts, :invokes, MapSet.new())` is changed to
    # ignore the `:invokes` option -> this reddens
    test "accepts a list of invoke ids and normalizes them into a MapSet" do
      routes = Routes.new(invokes: ["inv_1"])

      assert routes.invokes == MapSet.new(["inv_1"])
    end
  end

  describe "reachable?/2 - :self and :internal are reachable by construction" do
    # sabotage: `reachable?(_routes, :self), do: true` is changed to
    # `do: false` -> this reddens
    test ":self is always reachable, even against an empty snapshot" do
      assert Routes.reachable?(Routes.new(), :self)
    end

    # sabotage: `reachable?(_routes, :internal), do: true` is changed to
    # `do: false` -> this reddens
    test ":internal is always reachable, even against an empty snapshot" do
      assert Routes.reachable?(Routes.new(), :internal)
    end
  end

  describe "reachable?/2 - {:session, sid}" do
    # sabotage: the `{:session, session_id}` clause's `MapSet.member?(sessions, session_id)`
    # is changed to always `true` -> this reddens (an empty snapshot would
    # wrongly claim reachability)
    test "unreachable against an empty snapshot" do
      refute Routes.reachable?(Routes.new(), {:session, "sess_a"})
    end

    # sabotage: the same clause's `MapSet.member?/2` call has its arguments
    # swapped (`MapSet.member?(session_id, sessions)`) -> this crashes
    # instead of returning `true`, reddening for the right reason
    test "reachable when the session id is in the snapshot's sessions" do
      routes = Routes.new(sessions: ["sess_a"])

      assert Routes.reachable?(routes, {:session, "sess_a"})
      refute Routes.reachable?(routes, {:session, "sess_b"})
    end
  end

  describe "reachable?/2 - :parent" do
    # sabotage: `reachable?(%__MODULE__{parent?: parent?}, :parent), do: parent?`
    # is changed to `do: true` unconditionally -> this reddens (an empty
    # snapshot would wrongly claim a parent exists)
    test "reflects the snapshot's parent? field" do
      refute Routes.reachable?(Routes.new(), :parent)
      assert Routes.reachable?(Routes.new(parent?: true), :parent)
    end
  end

  describe "reachable?/2 - {:invoke, invokeid}" do
    # sabotage: the `{:invoke, invoke_id}` clause's `MapSet.member?(invokes, invoke_id)`
    # is changed to always `true` -> this reddens (an empty snapshot would
    # wrongly claim reachability)
    test "unreachable against an empty snapshot" do
      refute Routes.reachable?(Routes.new(), {:invoke, "inv_1"})
    end

    # sabotage: the same clause's `MapSet.member?/2` call has its arguments
    # swapped (`MapSet.member?(invoke_id, invokes)`) -> this crashes instead
    # of returning `true`, reddening for the right reason
    test "reachable when the invoke id is in the snapshot's invokes" do
      routes = Routes.new(invokes: ["inv_1"])

      assert Routes.reachable?(routes, {:invoke, "inv_1"})
      refute Routes.reachable?(routes, {:invoke, "inv_2"})
    end
  end

  describe "reachable?/2 - {:invalid, target}" do
    # sabotage: `reachable?(_routes, {:invalid, _target}), do: false` is
    # changed to `do: true` -> this reddens
    test "always unreachable, regardless of the snapshot" do
      routes = Routes.new(sessions: ["sess_a"], parent?: true, invokes: ["inv_1"])

      refute Routes.reachable?(routes, {:invalid, "not a real target"})
      refute Routes.reachable?(Routes.new(), {:invalid, "not a real target"})
    end
  end
end
