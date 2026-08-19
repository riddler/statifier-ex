defmodule Statifier.Session.ResumeTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering, Machine, MachineState}
  alias Statifier.{Parser, Position, Session, StreamOrder, Validator}

  # `Statifier.compile/2` (identified) is what `:resume` requires on both
  # sides (ADR-0060 decision 2); a bare `Compiler.compile/1` pipeline stays
  # available for the unidentified-chart refusal tests below.
  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp compile_unidentified!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp blob!(machine_state) do
    assert {:ok, blob} = Position.to_binary(machine_state)
    blob
  end

  defp wait_for_status(session, pred, attempts \\ 50)
  defp wait_for_status(_session, _pred, 0), do: flunk("status/1 never satisfied the predicate")

  defp wait_for_status(session, pred, attempts) do
    status = Session.status(session)

    if pred.(status) do
      status
    else
      Process.sleep(5)
      wait_for_status(session, pred, attempts - 1)
    end
  end

  # -- documents ------------------------------------------------------------

  # History (shallow, on "p"), a datamodel counter, and a generated <send>
  # on every entry into "a"/"b" - enough to make the persisted position's
  # history_values, datamodel, and send_counter all non-trivial (mirrors
  # `test/statifier/interpreter_rehydration_test.exs`'s own document).
  @history_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <history id="h" type="shallow">
              <transition target="a"/>
          </history>
          <state id="a">
              <onentry>
                  <assign location="count" expr="count + 1"/>
                  <send event="entered_a"/>
              </onentry>
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
                  <send event="entered_b"/>
              </onentry>
              <transition event="leave" target="outside"/>
          </state>
      </state>
      <state id="outside">
          <transition event="back" target="h"/>
      </state>
  </scxml>
  """

  defp history_positioned(machine) do
    {machine_state, _effects} = Interpreter.initialize(machine)
    {:ok, machine_state, _effects} = Interpreter.handle_event(machine_state, Event.external("go"))

    {:ok, machine_state, _effects} =
      Interpreter.handle_event(machine_state, Event.external("leave"))

    machine_state
  end

  @simple_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # A different chart revision of `@simple_document` - different source
  # bytes, so a different `Statifier.Machine.Identity` content hash - used
  # by the identity-mismatch refusal tests.
  @simple_document_v2 """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="c"/>
      </state>
      <state id="c"/>
  </scxml>
  """

  defp simple_positioned(machine) do
    {machine_state, _effects} = Interpreter.initialize(machine)
    machine_state
  end

  # A top-level <script> that must run exactly once, at the position's own
  # creation - never again on resume.
  @script_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <datamodel>
          <data id="inits" expr="0"/>
      </datamodel>
      <script>inits = inits + 1</script>
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # An <invoke> whose type is the built-in bare URI (registered with no
  # `:invoke_handlers` declared at all), so `active_invocations` is written
  # by the core's own invoke pass regardless of whether any session ever
  # resolves or starts a real child for it.
  @invoke_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke id="i1" type="http://www.w3.org/TR/scxml/" src="dummy:unresolved"/>
          <transition event="leave" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # An outstanding delayed send: `<send delay="...">` plans a
  # `{:schedule, ...}` instruction no pure-core position ever remembers -
  # only a live `Statifier.Session.Timers` does, and a resumed session
  # starts with an empty one (ADR-0060 decision 7).
  @timer_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <send event="fire" delay="60ms" id="d1"/>
          </onentry>
          <transition event="fire" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # -- continuity -------------------------------------------------------------

  describe "a resumed session continues from the persisted position" do
    # sabotage: `init_boot/3`'s resumed `boot/6` clause is changed to call
    # `Interpreter.initialize(machine, machine_opts)` (re-initializing)
    # instead of stamping the decoded position -> the resumed session's
    # configuration comes back the chart's *initial* configuration ("p"/"a")
    # instead of "outside", reddening the configuration assertion below.
    # Reverted and confirmed green.
    test "configuration, datamodel, history, and all six counters continue rather than restart" do
      machine_a = compile!(@history_document)
      machine_b = compile!(@history_document)

      original = history_positioned(machine_a)
      blob = blob!(history_positioned(machine_b))

      {:ok, session} = Session.start_link(machine_b, resume: blob)

      leaf_states = Statifier.active_leaf_states(Session.snapshot(session))
      assert leaf_states == MapSet.new(["outside"])

      snapshot = Session.snapshot(session)
      assert snapshot.datamodel["count"] == original.datamodel["count"]
      assert snapshot.macrostep == original.macrostep
      assert snapshot.microstep == original.microstep
      assert snapshot.round == original.round
      assert snapshot.send_counter == original.send_counter
      assert snapshot.invoke_counter == original.invoke_counter
      assert snapshot.timer_counter == original.timer_counter

      # History restoration: "back" from "outside" targets the shallow
      # history "h", whose recorded member is "b" (the state active when "p"
      # was last exited), not "a" (the history's own default target). "b"'s
      # full configuration includes its ancestor "p" (ADR-0005).
      Session.send_event(session, "back")
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["p", "b"]) end)

      assert status.configuration == MapSet.new(["p", "b"])
      # A live session performs "b"'s own generated `<send>`, which
      # self-routes onto the external inbox and drains in a second
      # macrostep - so this advances by two from `original`, not one; the
      # `>` check is what actually matters here (continuation, not reset).
      assert status.macrostep > original.macrostep
    end
  end

  describe "a resumed session performs no re-initialization" do
    # sabotage: `boot/6`'s resumed clause returns
    # `elem(Interpreter.initialize(machine_state.machine, machine_opts), 1)`
    # (the fresh-start effect list) instead of `[]` -> the subscriber below
    # receives the initial macrostep's entry effects (a
    # `{:effect, {:datamodel_init, _}}` among them), reddening the
    # `refute_receive`. Reverted and confirmed green.
    test "no entry effects for the initial states, and a top-level <script> does not run twice" do
      machine_a = compile!(@script_document)
      machine_b = compile!(@script_document)

      {machine_state, _effects} = Interpreter.initialize(machine_a)
      assert machine_state.datamodel["inits"] == 1
      blob = blob!(machine_state)

      {:ok, session} = Session.start_link(machine_b, resume: blob, subscribers: [self()])

      refute_receive {:statifier, _session_id, _message}, 50
      assert Session.snapshot(session).datamodel["inits"] == 1
    end
  end

  # -- session id -------------------------------------------------------------

  describe "session id" do
    # sabotage: `resolve_session_id/2`'s resumed clause is changed to ignore
    # `opts[:session_id]` entirely (`Keyword.get(opts, :session_id,
    # machine_state.datamodel["_sessionid"])` -> always
    # `machine_state.datamodel["_sessionid"]`) -> the override test below's
    # `Session.session_id/1` assertion reddens. Reverted and confirmed green.
    test "default resume keeps the position's _sessionid; :session_id overrides rewrite both sides" do
      machine = compile!(@simple_document)
      original = simple_positioned(machine)
      blob = blob!(original)

      {:ok, default_session} = Session.start_link(machine, resume: blob)
      assert Session.session_id(default_session) == original.datamodel["_sessionid"]

      assert Session.snapshot(default_session).datamodel["_sessionid"] ==
               original.datamodel["_sessionid"]

      {:ok, overridden_session} =
        Session.start_link(machine, resume: blob, session_id: "sess_override")

      assert Session.session_id(overridden_session) == "sess_override"
      assert Session.snapshot(overridden_session).datamodel["_sessionid"] == "sess_override"
    end
  end

  # -- refusals -----------------------------------------------------------

  describe "refusals" do
    # `init/1` returns `{:stop, {:resume, reason}}}` on a refusal
    # (`start_link/2`'s own `@doc`), and `start_link/2`'s link would
    # otherwise propagate that as an EXIT signal to this test process -
    # trapping it is what lets `Session.start_link/2`'s own `{:error, _}`
    # return value be asserted on directly instead.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "conflicting options: :trace, :datamodel, :max_macrostep_rounds, or :invoked_by alongside :resume" do
      machine = compile!(@simple_document)
      blob = blob!(simple_positioned(machine))

      assert {:error, {:resume, {:conflicting_options, conflicting}}} =
               Session.start_link(machine, resume: blob, trace: true)

      assert conflicting == [trace: true]

      assert {:error, {:resume, {:conflicting_options, _conflicting}}} =
               Session.start_link(machine, resume: blob, datamodel: %{})

      assert {:error, {:resume, {:conflicting_options, _conflicting}}} =
               Session.start_link(machine, resume: blob, max_macrostep_rounds: 5)

      assert {:error, {:resume, {:conflicting_options, _conflicting}}} =
               Session.start_link(machine, resume: blob, invoked_by: {self(), "inv1"})
    end

    # sabotage: `init/1`'s refusal arm is changed from
    # `{:error, reason} -> {:stop, {:resume, reason}}` to
    # `{:error, reason} -> {:stop, reason}` (dropping the `:resume` wrapper)
    # -> `Session.start_link/2` answers `{:error, :not_a_statifier_blob}`
    # instead of `{:error, {:resume, :not_a_statifier_blob}}`, reddening the
    # match below. Reverted and confirmed green.
    test "blob form: a foreign binary is :not_a_statifier_blob" do
      machine = compile!(@simple_document)

      assert {:error, {:resume, :not_a_statifier_blob}} =
               Session.start_link(machine, resume: <<1, 2, 3>>)
    end

    # sabotage: same as the foreign-binary test above (the `:resume`
    # wrapper dropped from `init/1`'s refusal arm) -> `Session.start_link/2`
    # answers `{:error, {:unsupported_format_version, 99}}` unwrapped,
    # reddening the match below. Reverted and confirmed green.
    test "blob form: an unsupported format version is reported unflattened" do
      machine = compile!(@simple_document)
      identity = Machine.identity(machine)
      blob = :erlang.term_to_binary({:statifier_position, 99, identity, %{}})

      assert {:error, {:resume, {:unsupported_format_version, 99}}} =
               Session.start_link(machine, resume: blob)
    end

    # sabotage: `decode_resume/2`'s blob-form clause guard is changed from
    # `when is_binary(blob)` to `when is_binary(blob) and byte_size(blob) >
    # 999_999_999` -> a normal-sized blob no longer matches that clause and
    # falls through to the struct-form clauses, which pattern-match on
    # `%MachineState{}` and raise `FunctionClauseError` on a binary instead
    # -> `Session.start_link/2` crashes rather than returning
    # `{:error, {:resume, {:identity_mismatch, _, _}}}`, reddening the match
    # below (and the sibling "unidentified target" test just below it, which
    # exercises the same dispatch clause). Reverted and confirmed green.
    test "blob form: a different chart revision is {:identity_mismatch, expected, actual}" do
      machine_v1 = compile!(@simple_document)
      machine_v2 = compile!(@simple_document_v2)
      blob = blob!(simple_positioned(machine_v1))

      assert {:error, {:resume, {:identity_mismatch, expected, actual}}} =
               Session.start_link(machine_v2, resume: blob)

      assert expected == Machine.identity(machine_v1)
      assert actual == Machine.identity(machine_v2)
    end

    # sabotage: same dispatch-clause mutation as the "different chart
    # revision" test just above. Reverted and confirmed green.
    test "blob form: an unidentified target Machine is :unidentified_chart" do
      identified = compile!(@simple_document)
      unidentified = compile_unidentified!(@simple_document)
      blob = blob!(simple_positioned(identified))

      assert {:error, {:resume, :unidentified_chart}} =
               Session.start_link(unidentified, resume: blob)
    end

    # sabotage: `decode_resume/2`'s second clause
    # (`%MachineState{}, %Machine{identity: nil} -> {:error, :unidentified_chart}`)
    # is deleted -> the target-unidentified half of this test falls through
    # to the general `Identity.matches?/2` clause instead, which answers
    # `{:error, {:identity_mismatch, source, nil}}` rather than
    # `:unidentified_chart`, reddening that assertion. Reverted and
    # confirmed green.
    test "struct form: either side unidentified is :unidentified_chart" do
      identified = compile!(@simple_document)
      unidentified = compile_unidentified!(@simple_document)

      unidentified_position = simple_positioned(unidentified)

      assert {:error, {:resume, :unidentified_chart}} =
               Session.start_link(identified, resume: unidentified_position)

      identified_position = simple_positioned(identified)

      assert {:error, {:resume, :unidentified_chart}} =
               Session.start_link(unidentified, resume: identified_position)
    end

    test "struct form: a mismatched identity is {:identity_mismatch, expected, actual}" do
      machine_v1 = compile!(@simple_document)
      machine_v2 = compile!(@simple_document_v2)
      position = simple_positioned(machine_v1)

      assert {:error, {:resume, {:identity_mismatch, expected, actual}}} =
               Session.start_link(machine_v2, resume: position)

      assert expected == Machine.identity(machine_v1)
      assert actual == Machine.identity(machine_v2)
    end

    # sabotage: `check_position_quiescent/1` is changed to always return
    # `:ok` (skipping the `MachineState.internal_queue_empty?/1` check) ->
    # the non-quiescent blob below is accepted instead of refused, reddening
    # the `{:error, _}` match. Reverted and confirmed green.
    test "a non-quiescent position is :position_not_quiescent" do
      machine = compile!(@simple_document)
      original = simple_positioned(machine)
      non_quiescent = MachineState.raise_internal(original, "probe", {:state, 0})
      blob = blob!(non_quiescent)

      assert {:error, {:resume, :position_not_quiescent}} =
               Session.start_link(machine, resume: blob)
    end

    # sabotage: `check_position_running/1`'s final catch-all clause
    # (`defp check_position_running(%MachineState{}), do: :ok`) is moved
    # ahead of the `running: false` and `status: :done` clauses -> every
    # position, this test's terminated one included, matches the
    # now-first catch-all and is accepted instead of refused, reddening the
    # `{:error, _}` match below. Reverted and confirmed green.
    test "a terminated position (running: false, status: :done) is :position_not_running" do
      machine = compile!(@simple_document)
      original = simple_positioned(machine)
      {:ok, done, _effects} = Interpreter.cancel(original)
      blob = blob!(done)

      assert {:error, {:resume, :position_not_running}} =
               Session.start_link(machine, resume: blob)
    end
  end

  # -- interpret/2 after resume (OQ-7) -----------------------------------

  describe "interpret/2 after resume" do
    # sabotage: `boot/6`'s resumed clause is changed to reset the rehydrated
    # `machine_state.macrostep` to `0` (`%{machine_state | macrostep: 0}`)
    # right after re-stamping routes/invoke_types -> the resumed session's
    # macrostep no longer continues from the persisted value, and
    # `status.macrostep == original.macrostep + 1` reddens (comes back `1`
    # instead). Reverted and confirmed green.
    test "effect and telemetry counter stamps continue from the resumed position, not from zero" do
      machine_a = compile!(@history_document)
      machine_b = compile!(@history_document)

      original = history_positioned(machine_a)
      blob = blob!(history_positioned(machine_b))

      {:ok, session} = Session.start_link(machine_b, resume: blob, subscribers: [self()])

      log_effect =
        {:log,
         %Effect.Log{
           label: "probe",
           value: nil,
           c_index: nil,
           owner: nil,
           macrostep: original.macrostep,
           microstep: original.microstep,
           round: original.round
         }}

      Session.interpret(session, [log_effect])
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:effect, {:log, %Effect.Log{label: "probe"}}}}

      Session.send_event(session, "leave")
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["outside"]) end)

      assert status.macrostep == original.macrostep + 1
    end
  end

  # -- active_invocations (OQ-5) -------------------------------------------

  describe "active_invocations on resume" do
    # sabotage: `Session.Invocations.pop/2`'s miss clause
    # (`{nil, ^entries} -> {nil, invocations}`) is changed to
    # `Map.fetch!(entries, invoke_id)` (raising on a miss instead of
    # no-op-ing) -> the resumed session crashes on the "leave" transition
    # below instead of staying alive, reddening `Process.alive?/1`. Reverted
    # and confirmed green.
    test "a position with a live invocation resumes; exiting the invoking state does not crash" do
      machine = compile!(@invoke_document)
      {machine_state, _effects} = Interpreter.initialize(machine)

      assert machine_state.active_invocations != %{}
      blob = blob!(machine_state)

      {:ok, session} = Session.start_link(machine, resume: blob)
      assert Session.snapshot(session).active_invocations == machine_state.active_invocations

      Session.send_event(session, "leave")
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)

      assert status.configuration == MapSet.new(["b"])
      assert Process.alive?(session)
    end
  end

  # -- timers (ADR-0060 decision 7) ----------------------------------------

  describe "timers on resume" do
    # sabotage: `Statifier.Session.Timers.count/1` is changed from
    # `MapSet.size(live)` to `MapSet.size(live) + 1` -> `pending_timers`
    # below comes back `1` instead of `0`, even though the resumed session's
    # `%Statifier.Session.Timers{}` is genuinely empty. Reverted and
    # confirmed green.
    test "a position persisted with an outstanding delayed send resumes with no live timer" do
      machine = compile!(@timer_document)
      {machine_state, _effects} = Interpreter.initialize(machine)
      blob = blob!(machine_state)

      {:ok, session} = Session.start_link(machine, resume: blob)
      assert Session.status(session).pending_timers == 0

      # Longer than the persisted send's 60ms delay - if a real timer had
      # somehow been re-armed, "fire" would have already been delivered.
      Process.sleep(100)

      status = Session.status(session)
      assert status.configuration == MapSet.new(["a"])
      assert status.pending_timers == 0
    end
  end

  # -- record: true + catch-up over a resumed position (ADR-0049/0060) ----

  describe "record: true and subscriber catch-up compose with a resumed session" do
    defp relay_to(test_pid) do
      spawn(fn -> relay_loop(test_pid) end)
    end

    defp relay_loop(test_pid) do
      receive do
        {:statifier, _session_id, _message} = envelope -> send(test_pid, {:late, envelope})
      end

      relay_loop(test_pid)
    end

    defp drain_late(session_id, acc \\ []) do
      receive do
        {:late, {:statifier, ^session_id, message}} -> drain_late(session_id, [message | acc])
      after
        100 -> Enum.reverse(acc)
      end
    end

    # sabotage: `init_boot/3`'s `Recording.new/3` call is changed to pass
    # `nil` instead of the resolved `anchor` (dropping the anchor blob) ->
    # `Statifier.Replay.run/1`'s replayed `prefix` starts at the chart's
    # *initial* configuration instead of the resumed one, so it diverges
    # from what the live subscriber actually received and
    # `prefix ++ suffix == full` reddens. Reverted and confirmed green.
    test "a late catch_up subscriber's replayed prefix plus its live suffix is the from-start stream" do
      machine = compile!(@history_document)
      blob = blob!(history_positioned(machine))

      {:ok, session} =
        Session.start_link(machine, resume: blob, record: true, subscribers: [self()])

      session_id = Session.session_id(session)

      relay = relay_to(self())

      Session.send_event(session, "back")
      _status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["p", "b"]) end)

      assert {:ok, recording} = Session.subscribe(session, relay, catch_up: true)

      Session.send_event(session, "leave")
      _status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["outside"]) end)

      assert {:ok, %{stream: prefix}} = Statifier.Replay.run(recording)
      assert prefix != []

      full = StreamOrder.drain(session_id)
      suffix = drain_late(session_id)

      assert prefix ++ suffix == full
      StreamOrder.assert_monotone(prefix ++ suffix)
    end
  end

  # -- Statifier.start_session/2 -------------------------------------------

  describe "Statifier.start_session/2" do
    # sabotage: n/a - this test only checks that `opts` reaches
    # `Session.start_link/2` unchanged through the supervised path
    # (`lib/statifier.ex`'s own `start_session/2` builds the child spec with
    # `opts` passed straight through), not a resume-specific behavior this
    # module's own `lib/` code implements.
    test "passes :resume through to the supervised path unchanged" do
      machine = compile!(@simple_document)
      original = simple_positioned(machine)
      blob = blob!(original)

      assert {:ok, pid} = Statifier.start_session(machine, resume: blob)
      assert Session.session_id(pid) == original.datamodel["_sessionid"]
      assert Session.snapshot(pid).configuration == original.configuration
    end
  end
end
