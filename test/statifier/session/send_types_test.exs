defmodule Statifier.Session.SendTypesTest do
  use ExUnit.Case, async: false

  # ADR-0069 decision 2 at the session: `:send_types` and
  # `:inherit_send_types` on `Statifier.Session.start_link/2`, stamped at
  # both boot arms, and the start-time refusal of a built-in spelling.
  # `async: false`: the inheritance tests start real children on
  # `Statifier.SessionSupervisor`, as `invoke_handler_inheritance_test.exs`
  # does. These tests read the core's stamp; the planner's hand-off of a
  # registered type is not part of this change.

  alias Statifier.{CrashReportProbe, Position, Session}
  alias Statifier.Send.{BasicHTTP, Types}
  alias Statifier.Session.{Invocations, Recording}

  defmodule SinkProcessor do
    @moduledoc false
  end

  # A processor that exports the optional `check_registration/2` and
  # accepts a registration only when its options carry `:shelf`.
  defmodule ShelfProcessor do
    @moduledoc false
    @spec check_registration(type :: String.t(), opts :: keyword()) ::
            :ok | {:error, {:missing_option, :shelf}}
    def check_registration(_type, opts) do
      if Keyword.has_key?(opts, :shelf), do: :ok, else: {:error, {:missing_option, :shelf}}
    end
  end

  # A processor whose `check_registration/2` breaks its contract as its
  # options say, and whose `_ioprocessors` entry is not a map, so a start
  # that reaches `init/1` is refused there with an `ArgumentError`.
  defmodule BrokenCheckProcessor do
    @moduledoc false
    @spec check_registration(type :: String.t(), opts :: keyword()) :: term()
    def check_registration(_type, opts) do
      case Keyword.fetch!(opts, :check) do
        :raise -> raise ArgumentError, "a check that raises"
        :throw -> throw(:a_check_that_throws)
        :junk -> :maybe
      end
    end

    @spec ioprocessors_entry(type :: String.t()) :: term()
    def ioprocessors_entry(_type), do: :not_a_map
  end

  # A processor that asks nothing at a fresh start and whose `_ioprocessors`
  # entry is not a map, so a start that reaches `init/1` is refused there
  # with this processor's `ArgumentError`.
  defmodule NonMapEntryProcessor do
    @moduledoc false
    @spec ioprocessors_entry(type :: String.t()) :: term()
    def ioprocessors_entry(_type), do: :not_a_map
  end

  # A processor whose `check_registration/2` raises, and whose
  # `_ioprocessors` entry is a map, so a start that reaches `init/1` is
  # answered by whichever other registration `init/1` cannot serve.
  defmodule RaisingCheckProcessor do
    @moduledoc false
    @spec check_registration(type :: String.t(), opts :: keyword()) :: no_return()
    def check_registration(_type, _opts), do: raise(ArgumentError, "a check that raises")

    @spec ioprocessors_entry(type :: String.t()) :: map()
    def ioprocessors_entry(_type), do: %{}
  end

  @send_types %{"myapp:sink" => SinkProcessor}

  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle"><state id="idle"/></scxml>)

  @parent_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke type="scxml">
              <content><![CDATA[#{@child_xml}]]></content>
          </invoke>
      </state>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp wait_until(pred, attempts \\ 50)
  defp wait_until(_pred, 0), do: flunk("condition never became true")

  defp wait_until(pred, attempts) do
    if pred.() do
      :ok
    else
      Process.sleep(5)
      wait_until(pred, attempts - 1)
    end
  end

  defp start_child_of(opts) do
    {:ok, parent} = Session.start_link(compile!(@parent_xml), opts)
    wait_until(fn -> Invocations.count(:sys.get_state(parent).invocations) == 1 end)
    [%{pid: child}] = Session.invocations(parent)
    child
  end

  describe "the registration refusal" do
    # `Session.start_link/2` links the caller to the process it starts, and a
    # refusal in `init/1` exits that process with the refusal as its reason;
    # trapping exits lets the `{:error, _}` return be asserted directly.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    # sabotage: `init_registered/3`'s `case` is replaced by a direct
    # `init_boot(machine, opts, resume)` call -> a map naming `"scxml"`
    # boots, `start_link/2` returns `{:ok, _}`, and this `{:error, _}` match
    # reddens. Confirmed red and reverted.
    test "a map naming a built-in spelling is refused before the session boots" do
      assert {:error, {:send_types, {:built_in_types, ["scxml"]}}} =
               Session.start_link(compile!(@chart),
                 send_types: Map.put(@send_types, "scxml", SinkProcessor)
               )
    end

    # sabotage: `built_in_send_types/1`'s filter is changed to
    # `&(SendTypes.classify(nil, &1) == :registered)` (never true against no
    # declaration) -> every built-in spelling is let through, the session
    # boots, and this `{:error, _}` match reddens. Confirmed red and reverted.
    test "every built-in spelling is named, sorted, in one refusal" do
      uri = "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"

      send_types = %{
        "scxml" => SinkProcessor,
        nil => SinkProcessor,
        uri => SinkProcessor,
        "myapp:sink" => SinkProcessor
      }

      assert {:error, {:send_types, {:built_in_types, [nil, ^uri, "scxml"]}}} =
               Session.start_link(compile!(@chart), send_types: send_types)
    end

    # sabotage: `init_registered/3`'s `[] -> init_boot(machine, opts,
    # resume)` arm is changed to `[] -> {:stop, {:send_types,
    # {:built_in_types, []}}}` -> a map naming only host types is refused,
    # and this `{:ok, _}` match reddens. Confirmed red and reverted.
    test "a map naming only host types boots" do
      assert {:ok, _session} = Session.start_link(compile!(@chart), send_types: @send_types)
    end
  end

  describe "a registration the processor rejects" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    # sabotage: n/a - the control for the probe: `init/1`'s built-in
    # refusal exits a spawned process, and the probe must hear its crash
    # report, or the `refute_receive` below proves nothing.
    test "the crash report probe hears a refusal init/1 makes" do
      CrashReportProbe.attach()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:send_types, {:built_in_types, ["scxml"]}}} =
                 Session.start_link(compile!(@chart), send_types: %{"scxml" => SinkProcessor})
      end)

      assert_receive {:crash_report, _report}, 1_000
    end

    # sabotage: the refusal moved back into `init/1` (`start_link/2` skips
    # `rejected_registration/1` and `init_registered/3` stops with the same
    # value) -> the named reason still comes back, but the spawned process's
    # `{:proc_lib, :crash}` report reaches the probe and `refute_receive`
    # reddens. Confirmed red and reverted.
    test "a fresh start is refused by name, with no crash report" do
      CrashReportProbe.attach()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                {:send_types,
                 {:invalid_registration, "library:shelve", {:missing_option, :shelf}}}} =
                 Session.start_link(compile!(@chart),
                   send_types: %{"library:shelve" => ShelfProcessor}
                 )
      end)

      refute_receive {:crash_report, _report}, 200
    end

    # sabotage: `Session`'s `rejected_registration/1` drops its
    # `SendTypes.registration?/1` arm -> the caller asks `split/1` with a
    # malformed value, raises `FunctionClauseError` before any process is
    # spawned, and the `{:error, {:function_clause, _}}` match reddens on
    # `{:raised_in_caller, FunctionClauseError}`. Confirmed red and reverted.
    test "a malformed registration is left to init/1, which answers as before" do
      for send_types <- [
            %{"library:shelve" => "not a module"},
            %{"library:shelve" => {ShelfProcessor, :not_a_list}},
            %{"library:shelve" => ShelfProcessor, "library:renew" => "not a module"}
          ] do
        machine = compile!(@chart)

        # A raise in the caller is caught into a value, so a caller-side
        # check that raises fails the match below rather than the test run.
        answer =
          ExUnit.CaptureLog.with_log(fn ->
            try do
              Session.start_link(machine, send_types: send_types)
            rescue
              exception -> {:raised_in_caller, exception.__struct__}
            end
          end)
          |> elem(0)

        assert {:error, {:function_clause, _stack}} = answer
      end
    end

    # sabotage: `Types.ask/3` drops its `rescue` and `catch` -> the raising
    # and throwing checks escape into the caller and the match reddens on
    # `{:raised_in_caller, _}`. Also red: `ask/3` answering `{:error, other}`
    # for a junk answer (a named refusal), and `rejected_registration/1`
    # ignoring `:unanswered` (the mixed map's shelf refusal wins). Confirmed
    # red and reverted.
    test "a check that breaks its contract leaves the whole start to init/1" do
      machine = compile!(@chart)

      for check <- [:raise, :throw, :junk],
          send_types <- [
            %{"library:broken" => {BrokenCheckProcessor, check: check}},
            %{
              "library:a-shelve" => ShelfProcessor,
              "library:b-broken" => {BrokenCheckProcessor, check: check}
            }
          ] do
        # A raise in the caller is caught into a value, so a caller-side
        # path that raises fails the match below rather than the test run.
        {answer, _log} =
          ExUnit.CaptureLog.with_log(fn ->
            try do
              Session.start_link(machine, send_types: send_types)
            rescue
              exception -> {:raised_in_caller, exception.__struct__}
            catch
              kind, value -> {:raised_in_caller, {kind, value}}
            end
          end)

        assert {:error, {%ArgumentError{message: message}, _stack}} = answer
        assert message =~ "must return a map"
      end
    end

    # sabotage: `rejected_registration/1` sorts the type strings descending ->
    # `"library:z-return"` is named and the match reddens. Confirmed red
    # and reverted.
    test "the first rejected type, in the order of the type strings, is named" do
      send_types = %{
        "library:z-return" => ShelfProcessor,
        "library:a-renew" => {ShelfProcessor, []},
        "library:m-hold" => {ShelfProcessor, shelf: "holds"}
      }

      assert {:error, {:send_types, {:invalid_registration, "library:a-renew", _reason}}} =
               Session.start_link(compile!(@chart), send_types: send_types)
    end

    # sabotage: `Types.rejection/2` drops its `function_exported?/3`
    # check -> `SinkProcessor` is asked, the start fails, and the `{:ok, _}`
    # match reddens. Confirmed red and reverted.
    test "an accepted registration, and a processor without the callback, boot" do
      assert {:ok, _session} =
               Session.start_link(compile!(@chart),
                 send_types: %{
                   "library:shelve" => {ShelfProcessor, shelf: "returns"},
                   "myapp:sink" => SinkProcessor
                 }
               )
    end

    # sabotage: `Session`'s `rejected_registration/1` ignores `:resume` ->
    # the resume is refused and the `{:ok, _}` match reddens. Confirmed red
    # and reverted.
    test "a resume is not asked: its persisted position stands" do
      machine = compile!(@chart)

      {:ok, first} =
        Session.start_link(machine,
          send_types: %{"library:shelve" => {ShelfProcessor, shelf: "returns"}}
        )

      assert {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      assert {:ok, _resumed} =
               Session.start_link(machine,
                 resume: blob,
                 send_types: %{"library:shelve" => ShelfProcessor}
               )
    end
  end

  describe "the named refusal's precedence over earlier start answers" do
    # ADR-0069's Amendment of 2026-10-02 asks `check_registration/2` in the
    # caller, before any process is spawned, so a fresh start whose Basic
    # HTTP registration has no `:base_url` is refused by name ahead of every
    # answer the spawned process, or `GenServer.start_link/3` itself, would
    # have given. Each case below first pins the earlier answer without that
    # registration, then the named refusal beside it.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    @no_base_url %{"basichttp" => BasicHTTP}
    @refused {:error,
              {:send_types, {:invalid_registration, "basichttp", {:missing_option, :base_url}}}}

    # A start answered in a value, with any raise in the caller caught into
    # one, so a caller-side path that raises fails the match below rather
    # than the test run.
    defp start_answer(machine, opts) do
      {answer, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          try do
            Session.start_link(machine, opts)
          rescue
            exception -> {:raised_in_caller, exception.__struct__}
          end
        end)

      answer
    end

    # sabotage: `start_link/2` calls `GenServer.start_link/3` before asking
    # `rejected_registration/1` (the check moved after the start) -> the
    # taken name answers `{:already_started, pid}` and the `@refused` match
    # reddens. Confirmed red and reverted.
    test "precedes a :name already taken" do
      machine = compile!(@chart)
      name = :send_types_precedence_taken_name
      {:ok, first} = Session.start_link(machine, name: name)

      assert {:error, {:already_started, ^first}} = start_answer(machine, name: name)

      assert @refused = start_answer(machine, name: name, send_types: @no_base_url)
      :ok = Session.stop(first)
    end

    # sabotage: as above, the check moved after the start -> the malformed
    # `:invoke_handlers` reaches `init/1`, which answers
    # `{:function_clause, _}`, and the `@refused` match reddens. Confirmed
    # red and reverted.
    test "precedes a malformed :invoke_handlers" do
      machine = compile!(@chart)

      assert {:error, {:function_clause, _stack}} =
               start_answer(machine, invoke_handlers: [:not_a_map])

      assert @refused =
               start_answer(machine, invoke_handlers: [:not_a_map], send_types: @no_base_url)
    end

    # sabotage: as above, the check moved after the start -> `init/1`
    # builds the entries and answers an `ArgumentError`, and the `@refused`
    # match reddens. Confirmed red and reverted.
    test "precedes another processor's non-map _ioprocessors entry" do
      machine = compile!(@chart)
      other = %{"library:notice" => NonMapEntryProcessor}

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               start_answer(machine, send_types: other)

      assert message =~ "must return a map"

      assert @refused = start_answer(machine, send_types: Map.merge(other, @no_base_url))
    end

    # sabotage: `Types.rejected_registration/1` ignores `:unanswered` (the
    # raising check no longer leaves the start to `init/1`) -> the Basic
    # HTTP registration is refused by name and the `ArgumentError` match
    # reddens. Confirmed red and reverted.
    test "does not apply beside a processor whose check breaks its contract" do
      machine = compile!(@chart)

      send_types =
        Map.merge(%{"library:notice" => RaisingCheckProcessor}, @no_base_url)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               start_answer(machine, send_types: send_types)

      assert message =~ "needs a :base_url"
    end
  end

  describe "the stamp at both boot arms" do
    # sabotage: `boot/7`'s fresh clause drops its `Keyword.put(:send_types,
    # SendTypes.from_send_types(send_types))` line -> the core boots with
    # `send_types: nil`, and the equality reddens. Confirmed red and
    # reverted.
    test "a fresh start stamps the snapshot derived from the map" do
      {:ok, session} = Session.start_link(compile!(@chart), send_types: @send_types)

      assert Session.snapshot(session).send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `boot/7`'s resumed clause drops its
    # `MachineState.put_send_types/2` call -> the decoded position's `nil`
    # survives, and the equality reddens. Confirmed red and reverted.
    test "a resume stamps the snapshot onto the persisted position" do
      machine = compile!(@chart)
      {:ok, first} = Session.start_link(machine, send_types: @send_types)
      assert {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} = Session.start_link(machine, resume: blob, send_types: @send_types)

      assert Session.snapshot(resumed).send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `Types.from_send_types/1`'s empty-map clause is deleted -> a
    # session started with no `:send_types` is stamped with an empty
    # `%Types{}`, and the `== nil` assertion reddens. Confirmed red and
    # reverted.
    test "no :send_types stamps nil and records no :send_types key" do
      {:ok, session} = Session.start_link(compile!(@chart), record: true)

      assert Session.snapshot(session).send_types == nil
      assert {:ok, recording} = Session.recording(session)
      refute Keyword.has_key?(Recording.opts(recording), :send_types)
    end

    # sabotage: `init_boot/3`'s recording line passes `machine_opts` unchanged
    # (the `Keyword.put(machine_opts, :send_types, send_types)` dropped) ->
    # the recording keeps the derived `%Types{}` snapshot instead of the
    # map, and the equality reddens. Confirmed red and reverted.
    test "a recording session records the :send_types map itself" do
      {:ok, session} =
        Session.start_link(compile!(@chart), record: true, send_types: @send_types)

      assert {:ok, recording} = Session.recording(session)
      assert Keyword.fetch(Recording.opts(recording), :send_types) == {:ok, @send_types}
    end
  end

  describe ":inherit_send_types" do
    # sabotage: `inherited_send_type_opts/1`'s
    # `%State{inherit_send_types: false}` clause is deleted -> a parent that
    # never opted in still hands its map down, the child is stamped, and the
    # `== nil` assertion reddens. Confirmed red and reverted.
    test "default off: an invoked child registers no send type" do
      child = start_child_of(send_types: @send_types)

      assert Session.snapshot(child).send_types == nil
    end

    # sabotage: `inherited_send_type_opts/1`'s `true`-shaped clause returns
    # `[]` -> the child boots with no map, and the equality reddens.
    # Confirmed red and reverted.
    test "on: an invoked child is stamped from the parent's map" do
      child = start_child_of(send_types: @send_types, inherit_send_types: true)

      assert Session.snapshot(child).send_types == Types.from_send_types(@send_types)
      assert :sys.get_state(child).inherit_send_types == true
    end
  end
end
