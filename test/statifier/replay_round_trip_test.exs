defmodule Statifier.ReplayRoundTripTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Replay
  alias Statifier.Session
  alias Statifier.Session.Recording
  alias Statifier.Validator

  # The recorder bead's acceptance criteria, executable: record a live run,
  # replay it, and assert both the effect stream and the terminal snapshot match
  # (Decision 4, plan lines ~269-287). Every case below drives a live
  # `record: true` session, drains its subscriber mailbox to quiescence, then
  # replays the recording it produced and compares.

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp state_index(machine, id) do
    {:ok, index} = Statifier.Machine.index(machine, id)
    index
  end

  # -- fixtures --------------------------------------------------------------

  defp two_state_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b">
            <transition event="go" target="c"/>
        </state>
        <state id="c"/>
    </scxml>
    """
  end

  defp final_chain_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b">
            <transition event="go" target="fin"/>
        </state>
        <final id="fin"/>
    </scxml>
    """
  end

  # -- helpers ----------------------------------------------------------------

  # Polls `status/1` until `pred` is true, or gives up after a generous
  # window - the same pattern `test/statifier/session_test.exs` uses, since a
  # timer firing or a scheduled send arrives asynchronously with no single
  # message this helper can `assert_receive` on.
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

  # Drains every `{:statifier, session_id, message}` currently sitting in (or
  # about to land in) this process's mailbox, envelope stripped, stopping
  # once none has arrived for a short quiet window. By the time a caller's
  # `wait_for_status/2` poll confirms the target position, every message the
  # drive that reached it produced is already enqueued here - `notify/2`
  # sends synchronously, in-process, before the session moves on to the next
  # input - so this is a drain, not a race.
  defp drain_stream(session_id, acc \\ []) do
    receive do
      {:statifier, ^session_id, message} -> drain_stream(session_id, [message | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # Drives a fresh `record: true, trace: true` session with `drive.(session)`,
  # collects its subscriber stream, then replays the recording it produced
  # and asserts both the stream and the terminal snapshot match (Decision 4).
  # Returns `{recording, stream, replay_result}` for case-specific assertions.
  defp round_trip(machine, opts, drive) do
    session_opts = Keyword.merge([record: true, trace: true, subscribers: [self()]], opts)
    {:ok, session} = Session.start_link(machine, session_opts)
    session_id = Session.session_id(session)

    drive.(session)

    stream = drain_stream(session_id)
    {:ok, recording} = Session.recording(session)
    snapshot = Session.snapshot(session)

    assert {:ok, result} = Replay.run(recording)
    assert result.stream == stream
    assert result.machine_state == snapshot

    {recording, stream, result}
  end

  # -- case 1: no interpret/2 --------------------------------------------

  describe "a run with no interpret/2" do
    # sabotage: `Statifier.Session.init/1`'s
    # `Recording.new(machine, Keyword.put(machine_opts, :session_id,
    # session_id))` call is changed to `Recording.new(machine, machine_opts)`
    # -> the recorded opts carry `session_id: nil` instead of the session's
    # resolved id, so `Recording.opts/1`'s `:session_id` key stays `nil` (not
    # merely defaulted, since it was explicitly requested) and
    # `MachineState.new/2`'s `is_binary(session_id)` guard on
    # `SystemVariables.initial/2` raises a `FunctionClauseError` inside
    # `Statifier.Replay.run/1`, which `round_trip/3`'s
    # `assert {:ok, result} = Replay.run(recording)` line surfaces as a
    # crash rather than a failed match. Reverted and confirmed green.
    test "the recording holds no {:interpret, _} entry, and the stream/snapshot still round-trip" do
      machine = compile!(final_chain_doc())

      {recording, stream, result} =
        round_trip(machine, [], fn session ->
          Session.send_event(session, "go")
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.status == :done end)
        end)

      refute Enum.any?(Recording.entries(recording), &match?({:interpret, _}, &1))

      assert length(stream) > 1
      assert {:halted, :done} in stream
      assert result.status == :done
    end
  end

  # -- case 2: with interpret/2 (Decision 1's proof case) -----------------

  describe "a run with interpret/2 (scheduling batch, firing, then an event)" do
    # sabotage: `Statifier.Replay`'s `perform_instruction({:schedule, send_id,
    # _delay_ms, _event}, state, _override)` clause is changed to *also*
    # `Inbox.enqueue_event/2` the event immediately, on top of the existing
    # `state.pending` credit (mirroring the double-delivery bug ADR-0034
    # exists to dissolve) -> the replayed run delivers the delayed "go" once
    # from the (mutated) `:schedule` instruction and a second time from the
    # recording's own `{:timer, "s1", _}` entry drawing its still-intact
    # credit, so `result.stream` gains an extra macrostep's worth of trace
    # and transition effects the live run's single delivery never produced,
    # reddening `round_trip/3`'s `result.stream == stream` assertion.
    # Reverted and confirmed green.
    test "the timer fires once in the replay, matching the live run's single delivery" do
      machine = compile!(two_state_doc())

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 30,
        macrostep: 1,
        microstep: 1
      }

      log_effect = %Effect.Log{label: "batch-log", value: nil, macrostep: 1, microstep: 1}

      {recording, _stream, result} =
        round_trip(machine, [], fn session ->
          Session.interpret(session, [{:send_delayed, send_delayed}, {:log, log_effect}])
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["c"]) end)
        end)

      effects = [{:send_delayed, send_delayed}, {:log, log_effect}]

      assert [
               {:interpret, ^effects},
               {:timer, "s1", %Event{name: "go"}},
               {:event, %Event{name: "go"}}
             ] = Recording.entries(recording)

      # What catches a double delivery is `round_trip/3`'s full ordered
      # `result.stream == stream` comparison, not a count: delivering the
      # timer's "go" twice still ends at "c" with two transitions, and what
      # moves is the *position* of those effects relative to the batch's own
      # `:log`. What this asserts locally is about the replayed stream - the
      # batch's log appears once there, so the batch was re-injected whole
      # rather than re-derived per effect.
      assert Enum.count(result.stream, &match?({:effect, {:log, ^log_effect}}, &1)) == 1
      assert length(result.stream) > 1

      assert result.machine_state.configuration ==
               MapSet.new([0, state_index(machine, "c")])
    end
  end

  # -- case 3: a multi-effect batch ----------------------------------------

  describe "a multi-effect interpret/2 batch" do
    # sabotage: `Statifier.Session.Recording.put_interpret/2` is changed from
    # storing the whole `effects` list to storing only `[hd(effects)]` -> the
    # recorded `{:interpret, _}` entry carries one effect instead of three, so
    # `Statifier.Replay.run/1` only re-derives the `:log` effect and never the
    # `:cancel_invoke`/`:send_delayed` pair, reddening `round_trip/3`'s own
    # `result.stream == stream` assertion (the live run's stream still has all
    # three) before this test's own pattern match against the full
    # three-effect batch is even reached. Reverted and confirmed green.
    test "batch boundaries survive: one interpret/2 call is one recorded entry, in order" do
      machine = compile!(two_state_doc())

      log_effect = %Effect.Log{label: "multi", value: nil, macrostep: 1, microstep: 1}

      cancel_invoke_effect = %Effect.CancelInvoke{
        invoke_id: "a.inv_1",
        state_index: 1,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 5_000,
        macrostep: 1,
        microstep: 1
      }

      effects = [
        {:log, log_effect},
        {:cancel_invoke, cancel_invoke_effect},
        {:send_delayed, send_delayed}
      ]

      {recording, stream, _result} =
        round_trip(machine, [], fn session ->
          Session.interpret(session, effects)
          wait_for_status(session, fn s -> s.pending_timers == 1 end)
        end)

      assert [{:interpret, ^effects}] = Recording.entries(recording)

      # `trace: true` also emits the initialization trace effects ahead of
      # the batch, and `Interpreter.initialize/2` always emits its own
      # `{:datamodel_init, _}` baseline ahead of those; filtering
      # both out isolates the batch's own effect order, which is what this
      # case is about (Decision 4 fixes `:trace` identically on both sides,
      # so it is not what this assertion checks).
      non_trace =
        Enum.reject(
          stream,
          &match?({:effect, {kind, _effect}} when kind in [:trace, :datamodel_init], &1)
        )

      assert non_trace == [
               {:effect, {:log, log_effect}},
               {:effect, {:cancel_invoke, cancel_invoke_effect}},
               {:effect, {:send_delayed, send_delayed}}
             ]
    end
  end

  # -- case 4: a cancel/1 run -----------------------------------------------

  describe "a cancel/1 run" do
    # sabotage: `Statifier.Replay`'s `drain_cancel/1` drops the
    # `halt_override: :cancelled` option on its `perform/3` call, keeping
    # only the bare `perform(effects)` -> the replayed run halts `:done`
    # instead of `:cancelled` (the core's own cancel effects still include
    # the terminal `{:done, _}` effect either way), so its last stream
    # message is `{:halted, :done}` where the live run's is `{:halted,
    # :cancelled}`, reddening `round_trip/3`'s own `result.stream == stream`
    # assertion. Reverted and confirmed green.
    test "cancel queued behind events halts :cancelled, snapshot compared post exit_interpreter/1" do
      machine = compile!(two_state_doc())

      {recording, stream, result} =
        round_trip(machine, [], fn session ->
          Session.send_event(session, "go")
          Session.send_event(session, "go")
          :ok = Session.cancel(session)
          wait_for_status(session, fn s -> s.status == :cancelled end)
        end)

      assert [
               {:event, %Event{name: "go"}},
               {:event, %Event{name: "go"}},
               :cancel
             ] = Recording.entries(recording)

      assert length(stream) > 1
      assert {:halted, :cancelled} in stream
      assert result.status == :cancelled

      # `cancel/1` reaches `exit_interpreter/1`, which empties `configuration`
      # by construction on both the live session and the replay - the same
      # equality this asserts covers that emptying, not just the position
      # reached before the cancel.
      assert result.machine_state.configuration == MapSet.new()
    end
  end

  # -- case 5: all four input kinds in one run ------------------------------

  describe "a run mixing all four input kinds" do
    # sabotage: `Statifier.Session`'s `handle_cast(:enqueue_cancel, state)`
    # drops its `record(state, &Recording.put_cancel/1)` call -> the `:cancel`
    # marker never reaches the recording, so the replayed run has no cancel to
    # drain and never emits the `{:halted, :cancelled}` message (nor the
    # cancel's own exit effects) the live run's stream ends with, reddening
    # `round_trip/3`'s `result.stream == stream` assertion before the
    # four-entry match below is reached. Observed red for exactly that reason
    # (this case and case 4 both), reverted, and confirmed green.
    test "interpret, timer, event and cancel are recorded in the order issued" do
      machine = compile!(two_state_doc())

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 20,
        macrostep: 1,
        microstep: 1
      }

      effects = [{:send_delayed, send_delayed}]

      {recording, stream, result} =
        round_trip(machine, [], fn session ->
          Session.interpret(session, effects)
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["c"]) end)
          :ok = Session.cancel(session)
          wait_for_status(session, fn s -> s.status == :cancelled end)
        end)

      # The four kinds, in the order the drive above issued them - this is
      # the session-level reading of "serialized input order" that the
      # per-kind cases each cover only a slice of.
      assert [
               {:interpret, ^effects},
               {:timer, "s1", %Event{name: "go"}},
               {:event, %Event{name: "go"}},
               :cancel
             ] = Recording.entries(recording)

      assert length(stream) > 1
      assert {:halted, :cancelled} in stream
      assert result.status == :cancelled
      assert result.machine_state.configuration == MapSet.new()
    end
  end

  # -- case 6: a pinned session_id ------------------------------------------

  describe "a pinned :session_id" do
    # sabotage: `Statifier.Session.init/1`'s
    # `Keyword.put(machine_opts, :session_id, session_id)` call is changed to
    # `Keyword.put(machine_opts, :session_id, "sess_wrong")`, ignoring the
    # resolved id entirely -> the recording's `Interpreter.initialize/2` call
    # writes "sess_wrong" into `datamodel["_sessionid"]` instead of the live
    # run's pinned "sess_fixed", so `result.machine_state` diverges from
    # `snapshot` on that one field, reddening `round_trip/3`'s own
    # `result.machine_state == snapshot` assertion before this test's own
    # `Recording.opts/1` check is even reached. Reverted and confirmed green.
    test "a supplied :session_id is carried into the recorded opts unchanged" do
      machine = compile!(two_state_doc())

      {recording, _stream, _result} =
        round_trip(machine, [session_id: "sess_fixed"], fn session ->
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
        end)

      assert Recording.opts(recording)[:session_id] == "sess_fixed"
    end
  end

  # -- case 7: a <send delay> / <cancel> document (ADR-0035's proof) -------

  defp send_cancel_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <datamodel>
            <data id="loc"/>
        </datamodel>
        <state id="a">
            <onentry>
                <send event="go" delay="10ms" idlocation="loc"/>
                <cancel sendid="never_sent"/>
            </onentry>
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  describe "a <send delay> / <cancel> document (ADR-0035's determinism proof)" do
    # sabotage: `Statifier.MachineState.new/2`'s `send_counter: 0` literal is
    # changed to seed from `System.unique_integer([:positive])` instead of
    # the fixed `0` -> the live run and its replay each mint their own
    # unrelated starting counter, so the replayed run's recorded `{:timer,
    # send_id, _}` entry no longer names a send_id the replayed
    # `Interpreter.initialize/2` scheduled, and `round_trip/3`'s own `assert
    # {:ok, result} = Replay.run(recording)` reddens outright with `{:error,
    # {:unscheduled_timer_firing, _}}` before this test's own `live_send_id
    # == "send_1"` assertion is even reached. Reverted and confirmed green.
    test "the generated send_id is identical across the live run and its replay" do
      machine = compile!(send_cancel_doc())

      {_recording, stream, result} =
        round_trip(machine, [], fn session ->
          wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
        end)

      live_send_id =
        Enum.find_value(stream, fn
          {:effect, {:send_delayed, %Effect.SendDelayed{send_id: id}}} -> id
          _other -> nil
        end)

      replayed_send_id =
        Enum.find_value(result.stream, fn
          {:effect, {:send_delayed, %Effect.SendDelayed{send_id: id}}} -> id
          _other -> nil
        end)

      assert live_send_id == "send_1"
      assert replayed_send_id == "send_1"
      assert live_send_id == replayed_send_id

      # `idlocation` writing the same id through to the datamodel on both
      # sides is the concrete, document-level reading of the same claim -
      # not just present on the effect, but bound identically where a
      # `<log expr="loc"/>` in this document would have read it.
      assert result.machine_state.datamodel["loc"] == live_send_id
    end
  end

  # -- case 8: a seam-crossing #_internal send (ADR-0044 decision 1) -------

  defp internal_send_to_final_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b">
            <onentry>
                <send event="ping" target="#_internal"/>
            </onentry>
            <transition event="ping" target="c"/>
        </state>
        <final id="c"/>
    </scxml>
    """
  end

  describe "a run that crosses the ADR-0039 seam via #_internal (ADR-0044 decision 1)" do
    # sabotage: `deliver_internal/6`'s deferral is reverted to the inline
    # `perform/3` call -> the live stream interleaves the re-entry ahead of
    # the outer batch's tail while replay keeps the recording's flat order,
    # so `round_trip/3`'s `result.stream == stream` fails on order alone -
    # same multiset, same terminal `%MachineState{}`. Reverted and confirmed
    # green.
    test "the recording carries the #_internal crossing and the drained stream ends :halted, :done" do
      machine = compile!(internal_send_to_final_doc())

      {recording, stream, result} =
        round_trip(machine, [], fn session ->
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.status == :done end)
        end)

      assert Enum.any?(Recording.entries(recording), &match?({:internal, _, _, _, _}, &1))
      assert List.last(stream) == {:halted, :done}
      assert result.status == :done
    end
  end

  # -- case 9: a seam-crossing error.communication (the other door) --------

  defp communication_error_to_final_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b">
            <onentry>
                <send event="e" target="#_scxml_nonexistent"/>
            </onentry>
            <transition event="error.communication" target="c"/>
        </state>
        <final id="c"/>
    </scxml>
    """
  end

  describe "a run that crosses the ADR-0039 seam via communication_error/4 (the other door)" do
    # sabotage: same mutation as the #_internal case above - reverting
    # `deliver_internal/6`'s deferral back to the inline `perform/3` call ->
    # the live stream interleaves the `error.communication` re-entry ahead of
    # the outer batch's tail while replay stays flat, reddening
    # `round_trip/3`'s `result.stream == stream` on order alone. Reverted and
    # confirmed green.
    test "an unreachable #_scxml_ target's error.communication crossing also round-trips in order" do
      machine = compile!(communication_error_to_final_doc())

      {recording, stream, result} =
        round_trip(machine, [], fn session ->
          Session.send_event(session, "go")
          wait_for_status(session, fn s -> s.status == :done end)
        end)

      assert Enum.any?(Recording.entries(recording), &match?({:internal, _, _, _, _}, &1))
      assert List.last(stream) == {:halted, :done}
      assert result.status == :done
    end
  end
end
