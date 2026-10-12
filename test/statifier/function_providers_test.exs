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

  defmodule MoreGuards do
    @moduledoc false
    @behaviour Predicator.FunctionProvider

    @impl Predicator.FunctionProvider
    def functions, do: %{"other_guard" => {1, :other_guard}}

    @spec other_guard(args :: [term()], context :: Predicator.Context.t()) :: {:ok, boolean()}
    def other_guard([x], _context), do: {:ok, x == 7}
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

    # sabotage: `Chart.from_binary/1` skips `check_opts/1` -> the doctored
    # blob reaches `Statifier.compile/2`, which raises, and the match goes red
    test "a chart blob whose options compile/2 would refuse is not a blob" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {:ok, blob} = Chart.to_binary(machine)
      {:statifier_chart, version, identity, source, _opts} = :erlang.binary_to_term(blob)

      for opts <- [[function_names: :my_guard], [function_providers: [Guards]]] do
        doctored = :erlang.term_to_binary({:statifier_chart, version, identity, source, opts})
        assert {:error, :not_a_statifier_blob} = Chart.from_binary(doctored)
      end
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

  describe "Statifier.compile/2, every place an expression can call" do
    # One undeclared call per expression site, each in its own chart. The
    # check reads every machine section (`:states`, `:transitions`,
    # `:contents`, `:data_elements`, `:global_scripts`).
    @sites %{
      "a <data expr>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <datamodel>
              <data id="x" expr="nope(1)"/>
          </datamodel>
          <state id="a"/>
      </scxml>
      """,
      "a top-level <script>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <script>x = nope(1)</script>
          <state id="a"/>
      </scxml>
      """,
      "a <script> in <onentry>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry><script>x = nope(1)</script></onentry>
          </state>
      </scxml>
      """,
      "a <send> <param expr>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e"><param name="p" expr="nope(1)"/></send>
              </onentry>
          </state>
      </scxml>
      """,
      "an <invoke> <param expr>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke type="scxml" src="child.scxml"><param name="p" expr="nope(1)"/></invoke>
          </state>
      </scxml>
      """,
      "a <donedata> <param expr>" => """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="f">
          <final id="f">
              <donedata><param name="p" expr="nope(1)"/></donedata>
          </final>
      </scxml>
      """
    }

    # sabotage: `FunctionCalls.check/2` takes only `:transitions` and
    # `:contents` -> the <data expr>, top-level <script>, <invoke> and
    # <donedata> charts compile and go red
    test "refuses an undeclared call wherever an expression is compiled" do
      for {site, xml} <- @sites do
        result = Statifier.compile(xml)

        assert match?({:error, [%Error{reason: {:unknown_function, "nope", _source}}]}, result),
               "#{site} was not refused: #{inspect(result, limit: 3)}"
      end
    end

    # sabotage: `FunctionCalls.check/2` drops its `Enum.uniq_by/2` -> the
    # name called twice in one expression reports twice and the count goes red
    test "reports each name once per element, in document order, at its own element" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="e" cond="zeta(1) and zeta(2)" target="b"/>
          </state>
          <state id="b">
              <transition event="e" cond="alpha(1)" target="a"/>
          </state>
      </scxml>
      """

      assert {:error, [first, second]} = Statifier.compile(xml)

      assert {first.reason, first.location.start_line} ==
               {{:unknown_function, "zeta", "zeta(1) and zeta(2)"}, 3}

      assert {second.reason, second.location.start_line} ==
               {{:unknown_function, "alpha", "alpha(1)"}, 6}
    end

    # sabotage: `calls/2` in function_calls.ex descends into every nested
    # list again -> the literal list reads as a call to `x` and the compile is
    # refused
    test "a literal list shaped like a call instruction is data, not a call" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="e" cond="['call', 'x', 1] == _event.data.l" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:ok, _machine} = Statifier.compile(xml)
    end

    # sabotage: `checked_function_names/1` keeps a list without the
    # `Enum.all?(names, &is_binary/1)` test -> no ArgumentError and the first
    # `assert_raise` goes red
    test "raises for a :function_names or :function_providers value of the wrong shape" do
      assert_raise ArgumentError, ~r/invalid :function_names/, fn ->
        Statifier.compile(@chart, function_names: ["my_guard", :other])
      end

      assert_raise ArgumentError, ~r/invalid :function_names/, fn ->
        Statifier.compile(@chart, function_names: "my_guard")
      end

      assert_raise ArgumentError, ~r/invalid :function_providers/, fn ->
        Statifier.compile(@chart, function_providers: ["nope"])
      end

      assert_raise ArgumentError, ~r/invalid :function_providers/, fn ->
        Statifier.compile(@chart, function_providers: Guards)
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

      assert_raise ArgumentError, ~r/shadowed_names/, fn ->
        MachineState.new(machine, function_providers: [Shadowing])
      end
    end
  end

  describe "two providers" do
    # sabotage: `decode_function_providers/2` keeps the reduce's reversed
    # order (no `Enum.reverse/1`) -> the decoded list reads
    # `[MoreGuards, Guards]` and the order assertion goes red
    test "both register, and a recording keeps their order through the codec" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
          <state id="idle">
              <transition event="go" cond="my_guard(_event.data.x) and other_guard(7)" target="pass"/>
          </state>
          <state id="pass"/>
      </scxml>
      """

      providers = [Guards, MoreGuards]
      {:ok, machine} = Statifier.compile(xml, function_providers: providers)
      assert machine.compile_opts == [function_names: ["my_guard", "other_guard"]]

      {:ok, session} = Session.start_link(machine, function_providers: providers, record: true)
      :ok = Session.send_event(session, go(42))
      assert leaves(Session.snapshot(session)) == MapSet.new(["pass"])

      {:ok, recording} = Session.recording(session)
      {:ok, blob} = Recording.to_binary(recording)
      {:ok, decoded} = Recording.from_binary(blob)
      assert Keyword.get(Recording.opts(decoded), :function_providers) == providers
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

    # sabotage: `Position.from_binary/2` keeps `:functions` in the decoded
    # payload (dropped from its `Map.drop/2` list) -> the stale map comes
    # back and the first `== nil` goes red
    test "from_binary/2 blanks a functions value a blob carries, and import/2 sets none" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {state, _effects} = Interpreter.initialize(machine, function_providers: [Guards])
      {:ok, blob} = Position.to_binary(state)

      {:statifier_position, version, identity, payload} = :erlang.binary_to_term(blob)
      stale = Map.put(payload, :functions, state.functions)
      doctored = :erlang.term_to_binary({:statifier_position, version, identity, stale})

      assert {:ok, decoded} = Position.from_binary(doctored, machine)
      assert decoded.functions == nil

      {:ok, exported} = Position.export(state)
      refute Map.has_key?(exported, :functions)
      assert {:ok, imported} = Position.import(machine, exported)
      assert imported.functions == nil
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
    test "start_link/2 refuses a provider list that does not resolve" do
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

    # sabotage: `resolve_provider/2`'s `:error` arm adds the name to
    # `modules` instead of `missing` -> the blob decodes and the error match
    # goes red
    test "a recording naming a provider module that is not loaded is refused by name" do
      {:ok, machine} = Statifier.compile(@chart, function_providers: [Guards])
      {:ok, session} = Session.start_link(machine, function_providers: [Guards], record: true)
      {:ok, recording} = Session.recording(session)
      {:ok, blob} = Recording.to_binary(recording)

      {:statifier_recording, version, chart, opts, entries, anchor} = :erlang.binary_to_term(blob)
      opts = Keyword.put(opts, :function_providers, ["Elixir.Statifier.NoSuchGuards"])

      doctored =
        :erlang.term_to_binary({:statifier_recording, version, chart, opts, entries, anchor})

      assert {:error, {:unknown_handler_modules, ["Elixir.Statifier.NoSuchGuards"]}} =
               Recording.from_binary(doctored)
    end

    # sabotage: `drop_empty_function_providers/1` keeps the key whatever its
    # value -> `Recording.opts/1` carries `function_providers: nil` and the
    # refutation goes red
    test "a session with no provider records no :function_providers key" do
      {:ok, machine} = Statifier.compile(@chart, function_names: ["my_guard"])

      for providers <- [nil, []] do
        {:ok, session} = Session.start_link(machine, function_providers: providers, record: true)
        {:ok, recording} = Session.recording(session)
        refute Keyword.has_key?(Recording.opts(recording), :function_providers)
      end
    end
  end
end
