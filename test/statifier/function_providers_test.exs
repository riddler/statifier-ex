defmodule Statifier.FunctionProvidersTest do
  use ExUnit.Case, async: true

  alias Statifier.{Chart, Evaluator, Event, Interpreter, MachineState, Position, Replay, Session}
  alias Statifier.Compiler.Error
  alias Statifier.Session.Recording

  defmodule Guards do
    @moduledoc false
    @behaviour Predicator.FunctionProvider

    @impl Predicator.FunctionProvider
    def functions, do: %{"my_guard" => {1, :my_guard}}

    @spec my_guard(args :: [term()], context :: Predicator.Context.t()) ::
            {:ok, boolean()} | {:error, String.t()}
    def my_guard([x], _context) when is_integer(x), do: {:ok, x > 10}
    def my_guard([_x], _context), do: {:error, "my_guard expects an integer"}
  end

  defmodule Shadowing do
    @moduledoc false
    @behaviour Predicator.FunctionProvider

    @impl Predicator.FunctionProvider
    def functions, do: %{"len" => {1, :len}, "In" => {1, :len}}

    @spec len(args :: [term()], context :: Predicator.Context.t()) :: {:ok, 0}
    def len([_x], _context), do: {:ok, 0}
  end

  # Waits in `idle` for `go`, so a position persisted before `go` has not
  # evaluated the guard yet.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="go" cond="my_guard(_event.data.x)" target="pass"/>
          <transition event="go" target="fail"/>
      </state>
      <state id="pass"/>
      <state id="fail"/>
  </scxml>
  """

  defp go(x), do: Event.external("go", data: %{"x" => x})

  defp leaves(machine_state), do: Statifier.active_leaf_states(machine_state)

  describe "Statifier.compile/2" do
    # sabotage: `check_function_calls/2` in lib/statifier.ex keeps none of
    # `FunctionCalls.check/2`'s errors (`|> Enum.take(0)`) -> the chart
    # compiles and the error match goes red
    test "refuses a chart that calls a function no provider registers" do
      assert {:error, [%Error{reason: {:unknown_function, "my_guard", source}} = error]} =
               Statifier.compile(@chart)

      assert source == "my_guard(_event.data.x)"
      assert error.location.start_line == 3
    end

    # sabotage: `declare_function_names/1` drops the provider names (answers `[]`
    # for them) -> the compile is refused and the match goes red
    test "compiles the chart when a provider registers the function" do
      assert {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      assert machine.compile_opts == [function_names: ["my_guard"]]
    end

    # sabotage: `checked_function_names/1` answers `[]` for a valid list ->
    # nothing is declared and the compile is refused -> red
    test "compiles the chart when :function_names declares the name, with no module" do
      assert {:ok, _machine} = Statifier.compile(@chart, function_names: ["my_guard"])
    end

    # sabotage: `:function_names` is taken out of `@persisted_compile_opts` -> the
    # blob recompiles with nothing declared and `from_binary/1` answers
    # `{:compile_failed, _}` -> red
    test "a chart blob recompiles without the provider modules" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {:ok, blob} = Chart.to_binary(machine)

      assert {:ok, decoded} = Chart.from_binary(blob)
      assert decoded.compile_opts == [function_names: ["my_guard"]]
    end

    # sabotage: the `[]` arm of `declare_function_names/1` puts
    # `function_names: []` -> compile_opts gains the key and this equality
    # goes red
    test "a chart that calls only In and builtins persists no :function_names" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition cond="In('a') and len('xy') == 2" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:ok, machine} = Statifier.compile(xml)
      assert machine.compile_opts == []
    end

    # sabotage: `FunctionCalls.check/2` takes only `:transitions` from the machine
    # -> the call inside `<onentry>` is not found and the compile succeeds -> red
    test "finds a call in executable content, not only in a transition cond" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <datamodel>
              <data id="ok" expr="false"/>
          </datamodel>
          <state id="a">
              <onentry>
                  <assign location="ok" expr="other_guard(1)"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unknown_function, "other_guard", "other_guard(1)"}}]} =
               Statifier.compile(xml)
    end

    # sabotage: `from_providers/1`'s shadowing filter keeps no name -> the provider
    # merges over `len` and `In` and no error is raised -> red
    test "raises for a provider that shadows In or a builtin" do
      assert_raise ArgumentError, ~r/shadowed_names.*In.*len/, fn ->
        Statifier.compile(@chart, function_providers: [Shadowing])
      end
    end
  end

  describe "evaluation" do
    # sabotage: `Evaluator.context/1` passes `nil` to `base_context/1` instead of
    # `machine_state.functions` -> the guard's call fails, `error.execution`
    # is raised, and the chart takes the `fail` branch -> red
    test "a registered guard decides the transition" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])

      {state, _effects} = Interpreter.initialize(machine, function_providers: [Guards])
      assert {:ok, high, _effects} = Interpreter.handle_event(state, go(42))
      assert leaves(high) == MapSet.new(["pass"])

      {state, _effects} = Interpreter.initialize(machine, function_providers: [Guards])
      assert {:ok, low, _effects} = Interpreter.handle_event(state, go(3))
      assert leaves(low) == MapSet.new(["fail"])
    end

    # sabotage: `base_context/1`'s non-nil clause returns `Functions.base_context()`
    # unchanged -> "my_guard" is absent from the context's functions -> red
    test "the context holds the host function beside In and the builtins" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])

      context = Evaluator.context(MachineState.new(machine, function_providers: [Guards]))
      assert context.functions["my_guard"] == {1, {Guards, :my_guard}}
      assert {1, {Statifier.Evaluator.Functions, :in_state}} = context.functions["In"]
      assert Map.has_key?(context.functions, "len")

      refute Map.has_key?(Evaluator.context(MachineState.new(machine)).functions, "my_guard")
    end

    # sabotage: `from_providers!/1` answers `nil` on a refusal instead of raising
    # -> no error and `assert_raise` goes red
    test "MachineState.new/2 raises for a provider that does not load" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])

      assert_raise ArgumentError, ~r/invalid_provider/, fn ->
        MachineState.new(machine, function_providers: [Statifier.FunctionProvidersTest.Missing])
      end
    end
  end

  describe "Position" do
    # sabotage: `Position.to_binary/1` keeps `:functions` in its payload -> the
    # payload refutation goes red
    test "a persisted position drops the host functions, and put_function_providers/2 restores them" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {state, _effects} = Interpreter.initialize(machine, function_providers: [Guards])
      {:ok, blob} = Position.to_binary(state)

      {:statifier_position, _version, _identity, payload} = :erlang.binary_to_term(blob)
      refute Map.has_key?(payload, :functions)

      assert {:ok, decoded} = Position.from_binary(blob, machine)
      assert decoded.functions == nil

      restamped = MachineState.put_function_providers(decoded, [Guards])
      assert restamped.functions == state.functions
      assert {:ok, after_go, _effects} = Interpreter.handle_event(restamped, go(42))
      assert leaves(after_go) == MapSet.new(["pass"])
    end
  end

  describe "Statifier.Session" do
    # sabotage: the resumed `boot/7` clause drops
    # `MachineState.put_function_providers/2` -> the resumed position
    # evaluates with no host function and lands in `fail` -> red
    test "a resumed session keeps the provider" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {:ok, first} = Session.start_link(machine, function_providers: [Guards])
      {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} = Session.start_link(machine, resume: blob, function_providers: [Guards])
      :ok = Session.send_event(resumed, go(42))

      assert leaves(Session.snapshot(resumed)) == MapSet.new(["pass"])
    end

    # sabotage: `Replay.start_state/1`'s anchored branch stamps nothing in place of
    # `MachineState.put_function_providers/2` -> the replay evaluates the
    # guard with no host function and lands in `fail` -> red
    test "a recording made by a resumed session replays with the provider" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {:ok, first} = Session.start_link(machine, function_providers: [Guards])
      {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} =
        Session.start_link(machine, resume: blob, function_providers: [Guards], record: true)

      :ok = Session.send_event(resumed, go(42))
      assert leaves(Session.snapshot(resumed)) == MapSet.new(["pass"])

      {:ok, recording} = Session.recording(resumed)
      assert {:ok, result} = Replay.run(recording)
      assert leaves(result.machine_state) == MapSet.new(["pass"])
    end

    # sabotage: `checked_function_providers/1` returns the bare reason, without the
    # `:function_providers` tag -> the error match goes red
    test "start_link/2 refuses a provider list that does not resolve, before booting" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])

      assert {:error, {:function_providers, {:shadowed_names, ["In", "len"]}}} =
               Session.start_link(machine, function_providers: [Shadowing])

      assert {:error, {:function_providers, {:invalid_provider, "nope", "not a module name"}}} =
               Session.start_link(machine, function_providers: ["nope"])

      assert {:error, {:function_providers, {:not_a_list, Guards}}} =
               Session.start_link(machine, function_providers: Guards)
    end

    # sabotage: `decode_function_providers/2` deletes the key instead of putting the
    # resolved modules -> the replay has no host function and lands in `fail` -> red
    test "a recording replays with the recorded provider, through the binary codec" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])

      {:ok, session} =
        Session.start_link(machine, function_providers: [Guards], record: true)

      :ok = Session.send_event(session, go(42))
      assert leaves(Session.snapshot(session)) == MapSet.new(["pass"])

      {:ok, recording} = Session.recording(session)
      assert Keyword.get(Recording.opts(recording), :function_providers) == [Guards]

      {:ok, blob} = Recording.to_binary(recording)
      {:ok, decoded} = Recording.from_binary(blob)
      assert {:ok, result} = Replay.run(decoded)
      assert leaves(result.machine_state) == MapSet.new(["pass"])
    end
  end
end
