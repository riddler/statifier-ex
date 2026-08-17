defmodule Statifier.ReplayTest do
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

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

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

  defp cancel_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a"/>
    </scxml>
    """
  end

  defp livelock_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition target="a"/>
        </state>
    </scxml>
    """
  end

  defp event(name), do: Event.external(name)

  defp send_delayed(send_id, delay_ms) do
    %Effect.SendDelayed{
      event: "go",
      target: nil,
      send_id: send_id,
      delay_ms: delay_ms,
      macrostep: 1,
      microstep: 1
    }
  end

  defp cancel_effect(send_id) do
    %Effect.Cancel{send_id: send_id, macrostep: 1, microstep: 1}
  end

  defp state_index(machine, id) do
    {:ok, index} = Statifier.Machine.index(machine, id)
    index
  end

  describe "run/1" do
    # sabotage: `to_result/1`'s `status: state.halted || :running` is changed
    # to hardcode `status: :done` -> this assertion reddens on the `:running`
    # mismatch. Reverted and confirmed green.
    test "an empty recording replays to the post-initialize state" do
      machine = compile!(two_state_doc())
      recording = Recording.new(machine, session_id: "sess_replay_test")

      assert {:ok, result} = Replay.run(recording)
      assert result.status == :running
      assert result.machine_state.configuration != MapSet.new()
      # `Interpreter.initialize/2`'s own `{:datamodel_init, _}` baseline
      # is the one effect a fresh `initialize/2` always produces,
      # "empty" recording or not - it is a core effect, not something the
      # recording's own entries contributed.
      assert [{:effect, {:datamodel_init, _init}}] = result.stream
    end

    # sabotage: `apply_entry({:event, event}, state)` drains without first
    # enqueuing the event onto the inbox (drops the `Inbox.enqueue_event/2`
    # call) -> the configuration never advances, reddening the assertion.
    # Reverted and confirmed green.
    test "an event entry advances the configuration" do
      machine = compile!(two_state_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_event(event("go"))

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "b")])
    end

    # sabotage: `apply_entry(:cancel, state)` drains without enqueuing the
    # cancel marker (drops `Inbox.enqueue_cancel/1`) -> the cancel never
    # drains, so `result.status` stays `:running` instead of `:cancelled`,
    # reddening both assertions below. Reverted and confirmed green.
    test "a cancel entry halts :cancelled and emits {:halted, :cancelled}" do
      machine = compile!(cancel_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_cancel()

      assert {:ok, result} = Replay.run(recording)
      assert result.status == :cancelled
      assert {:halted, :cancelled} in result.stream
    end

    # sabotage: `perform_instruction({:enqueue_event, event}, state,
    # _override)` is changed to drop the event without enqueuing it -> the
    # batch's re-enqueued `go` event never reaches the core, so the
    # configuration stays "a" instead of advancing to "b", reddening the
    # assertion. Reverted and confirmed green.
    test "an interpret/2 batch with a targetless :send re-enqueues and drains" do
      machine = compile!(two_state_doc())

      send_effect =
        {:send, %Effect.Send{event: "go", target: nil, macrostep: 1, microstep: 1}}

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([send_effect])

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "b")])
      assert Enum.any?(result.stream, &match?({:effect, {:send, _}}, &1))
    end

    # sabotage: `perform_instruction({:start_child, %Invoke{}, _effect}, state,
    # _override)` is changed from `state` to `append(state, {:unroutable,
    # effect})`, treating it like the `:unroutable` clause it deliberately is
    # not -> `result.stream` gains a second entry the live session's own
    # `{:start_child, _, _}` performer never produces (it starts a process and
    # writes a table entry, it does not notify `:unroutable`), reddening the
    # exact-list equality assertion below. Reverted and confirmed green.
    test "a supported <invoke>'s {:start_child, ...} instruction is a no-op beyond its own {:notify, ...}" do
      machine = compile!(two_state_doc())

      invoke_effect =
        {:invoke,
         %Effect.Invoke{
           invoke_id: "i1",
           state_index: 0,
           invoke_index: 0,
           macrostep: 1,
           microstep: 1
         }}

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([invoke_effect])

      assert {:ok, result} = Replay.run(recording)
      # `Interpreter.initialize/2`'s own `{:datamodel_init, _}` baseline
      # precedes the recorded interpret batch's own effect.
      assert [{:effect, {:datamodel_init, _init}}, {:effect, ^invoke_effect}] = result.stream
    end

    # -- Decision 6: the live-invocation set --------------------------------

    # sabotage: `perform_instruction({:start_child, %Invoke{invoke_id:
    # invoke_id}, _effect}, state, _override)` is changed to leave
    # `state.live_invoke_ids` untouched (`state` instead of `%{state |
    # live_invoke_ids: MapSet.put(...)}`) -> the recorded entry's delivering
    # invocation "i1" is never found live, so `apply_entry/2`'s
    # `{:invoked_event, _, _}` clause discards it instead of delivering it,
    # and the configuration stays on "a" instead of advancing to "b",
    # reddening the assertion. Reverted and confirmed green.
    test "a recorded entry whose delivering invocation is still live (started, uncancelled) is delivered" do
      machine = compile!(two_state_doc())

      invoke_effect =
        {:invoke,
         %Effect.Invoke{
           invoke_id: "i1",
           state_index: 0,
           invoke_index: 0,
           macrostep: 1,
           microstep: 1
         }}

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([invoke_effect])
        |> Recording.put_invoked_event("i1", Event.external("go", invokeid: "i1"))

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "b")])
    end

    # sabotage: `perform_instruction({:stop_child, invoke_id}, state,
    # _override)` is changed to leave `state.live_invoke_ids` untouched
    # (`state` instead of `%{state | live_invoke_ids: MapSet.delete(...)}`)
    # -> "i1" stays live in Replay's own bookkeeping even after the
    # `:cancel_invoke` effect that a real session would have popped it on,
    # so the later recorded "go" event is delivered instead of discarded and
    # the configuration advances to "b", reddening the assertion (which
    # expects it to stay on "a", matching what a live session actually does
    # once it has popped the table entry). Reverted and confirmed green.
    test "a recorded entry whose delivering invocation was already stopped is discarded" do
      machine = compile!(two_state_doc())

      invoke_effect =
        {:invoke,
         %Effect.Invoke{
           invoke_id: "i1",
           state_index: 0,
           invoke_index: 0,
           macrostep: 1,
           microstep: 1
         }}

      cancel_invoke_effect =
        {:cancel_invoke,
         %Effect.CancelInvoke{invoke_id: "i1", state_index: 0, macrostep: 1, microstep: 1}}

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([invoke_effect, cancel_invoke_effect])
        |> Recording.put_invoked_event("i1", Event.external("go", invokeid: "i1"))

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "a")])
    end

    # sabotage: `perform_instruction({:schedule, send_id, _delay_ms, _event},
    # state, _override)` is changed from incrementing `state.pending[send_id]`
    # to instead immediately enqueuing the event onto the inbox (mirroring
    # the double-delivery bug ADR-0034 exists to dissolve) -> the `go` event
    # is delivered once by the `:schedule` clause itself and a second time by
    # the `{:timer, ...}` entry's own delivery, so the configuration advances
    # two steps (to "c") instead of one (to "b"), reddening the assertion.
    # Reverted and confirmed green.
    test "a :send_delayed batch followed by its {:timer, ...} entry delivers the event exactly once" do
      machine = compile!(two_state_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([{:send_delayed, send_delayed("s1", 40)}])
        |> Recording.put_timer("s1", event("go"))

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "b")])
    end

    # sabotage: `perform_instruction({:cancel_timers, send_id}, state,
    # _override)` is changed to `Map.delete/2` the pending count outright
    # instead of moving it into `state.raced` -> the later `{:timer, ...}`
    # entry finds no credit in either map and `run/1` returns
    # `{:error, {:unscheduled_timer_firing, "s1"}}` instead of delivering the
    # event, reddening the assertion. Reverted and confirmed green.
    test "a :cancel effect followed by that send id's {:timer, ...} entry delivers via the raced credit" do
      machine = compile!(two_state_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([{:send_delayed, send_delayed("s1", 30)}])
        |> Recording.put_interpret([{:cancel, cancel_effect("s1")}])
        |> Recording.put_timer("s1", event("go"))

      assert {:ok, result} = Replay.run(recording)
      assert result.machine_state.configuration == MapSet.new([0, state_index(machine, "b")])
    end

    # sabotage: `draw_credit/2` is changed to always return `{:ok, state}`
    # unconditionally instead of checking `pending`/`raced` for a positive
    # count -> a firing with no credit anywhere is accepted instead of
    # erroring, reddening the assertion. Reverted and confirmed green.
    test "a {:timer, ...} entry for an unscheduled send id returns an error" do
      machine = compile!(two_state_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_timer("never-scheduled", event("go"))

      assert Replay.run(recording) == {:error, {:unscheduled_timer_firing, "never-scheduled"}}
    end

    # sabotage: `drain/1`'s `{:ok, {:event, _event}, _inbox} when state.halted
    # != nil -> state` clause condition is changed to `state.halted == nil`,
    # which falls through to the unconditional drain clause instead -> a
    # `:budget_exhausted` halt leaves `machine_state.running` true (ADR-0019),
    # so the queued event is wrongly drained too, re-running the livelocked
    # document to a second budget exhaustion and appending a second
    # `{:halted, :budget_exhausted}` to the stream, reddening the count
    # assertion below. Reverted and confirmed green.
    test "an event entry after a halt stays queued with no further stream messages" do
      machine = compile!(livelock_doc())

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test", max_macrostep_rounds: 5)
        |> Recording.put_event(event("ignored"))

      assert {:ok, result} = Replay.run(recording)
      assert result.status == :budget_exhausted
      assert Enum.count(result.stream, &match?({:halted, :budget_exhausted}, &1)) == 1
    end

    # sabotage: `perform/3`'s `Enum.reduce/3` is changed from `Effects.plan()
    # |> Enum.reduce(...)` to `Effects.plan() |> Enum.reverse() |>
    # Enum.reduce(...)`, reversing instruction order within one batch -> the
    # two `{:effect, {:log, _}}` messages arrive in reverse order, reddening
    # the assertion. Reverted and confirmed green.
    test "a multi-effect batch preserves effect order in the stream" do
      machine = compile!(two_state_doc())

      log_one = {:log, %Effect.Log{label: "one", value: nil, macrostep: 1, microstep: 1}}
      log_two = {:log, %Effect.Log{label: "two", value: nil, macrostep: 1, microstep: 1}}

      recording =
        machine
        |> Recording.new(session_id: "sess_replay_test")
        |> Recording.put_interpret([log_one, log_two])

      assert {:ok, result} = Replay.run(recording)

      # `Interpreter.initialize/2`'s own `{:datamodel_init, _}` baseline
      # precedes the recorded interpret batch's own two effects.
      assert [
               {:effect, {:datamodel_init, _init}},
               {:effect, ^log_one},
               {:effect, ^log_two}
             ] = result.stream
    end
  end

  # -- <send> routing (ADR-0039) -------------------------------------------

  describe "run/1 over a recorded <send> routing run" do
    defp internal_and_communication_error_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e1" target="#_internal"/>
                  <send event="e2" target="#_scxml_foo"/>
              </onentry>
              <transition event="e1" target="b"/>
          </state>
          <state id="b">
              <transition event="error.communication" target="c"/>
          </state>
          <state id="c"/>
      </scxml>
      """
    end

    # sabotage: `apply_entry/2`'s `{:internal, kind, name, origin, opts}`
    # clause is deleted, leaving no catch-all -> replaying the recording
    # below raises `FunctionClauseError` from `Replay.run/1` instead of
    # returning `{:ok, result}`, reddening the configuration assertion.
    # Reverted and confirmed green.
    test "a recorded #_internal delivery and a failed #_scxml_foo send reach the same final configuration as the live run" do
      machine = compile!(internal_and_communication_error_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      live_status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["c"]) end)
      {:ok, recording} = Session.recording(session)

      assert {:ok, result} = Replay.run(recording)

      replayed_configuration =
        result.machine_state.configuration
        |> Enum.map(&Statifier.Machine.id(machine, &1))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      assert replayed_configuration == live_status.configuration
    end
  end

  describe "run/1 over a recorded #_parent send (no live parent to reach)" do
    defp parent_route_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="ping" target="#_parent"/>
              </onentry>
              <transition event="error.communication" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # `:parent` still falls into `perform_instruction/3`'s catch-all
    # `{:deliver, _route, _event, _effect} -> state` clause - Phase 3 adds no
    # `Replay` clause of its own (this module's moduledoc, "`{:deliver,
    # ...}`/`{:raise, ...}` defer to the recorded `{:internal, ...}` entry"):
    # a replayed session has no live parent to reach either way, and the
    # live session's own `error.communication` write is what actually moves
    # the configuration, reached here through the recorded `{:internal, ...}`
    # entry, not through this clause.
    #
    # sabotage: that catch-all clause's body is changed from `state` to
    # `append(state, {:unroutable, effect})`, mirroring the mutation the
    # `{:start_child, ...}` no-op test above uses for the same shape of
    # claim -> `result.stream` gains a second entry the live session's own
    # resolver never produces (`Statifier.Session` never plans `:parent` as
    # `{:unroutable, _}`), reddening the exact-list equality assertion below.
    # Reverted and confirmed green.
    test "a recorded #_parent send reaches the same final configuration as the live run, with no extra stream entry" do
      machine = compile!(parent_route_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      live_status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      {:ok, recording} = Session.recording(session)

      assert {:ok, result} = Replay.run(recording)

      replayed_configuration =
        result.machine_state.configuration
        |> Enum.map(&Statifier.Machine.id(machine, &1))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      assert replayed_configuration == live_status.configuration
      refute Enum.any?(result.stream, &match?({:unroutable, _}, &1))
    end
  end

  describe "a delayed send through a real recording (widened {:schedule, ...})" do
    defp two_state_delay_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="go" delay="10ms"/>
              </onentry>
              <transition event="go" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `perform_instruction({:schedule, send_id, _delay_ms, _route,
    # _event, _effect}, state, _override)` (the widened five-argument
    # pattern) is narrowed back to the old four-argument shape,
    # `{:schedule, send_id, _delay_ms, _event}` -> the recorded five-element
    # `{:interpret, [{:send_delayed, _}]}` entry's own `{:schedule, ...}`
    # instruction (now six elements, tag included) no longer matches any
    # clause, and `Replay.run/1` raises `FunctionClauseError` instead of
    # returning `{:ok, result}`, reddening the assertion below. Reverted and
    # confirmed green.
    test "a real live-recorded delayed send replays to the same final configuration" do
      machine = compile!(two_state_delay_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      _status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      {:ok, recording} = Session.recording(session)
      assert {:ok, result} = Replay.run(recording)

      assert result.machine_state.configuration ==
               MapSet.new([0, state_index(machine, "b")])
    end
  end

  # Polls `Session.status/1` until `pred` is true, or gives up after a
  # generous window - mirrors `Statifier.SessionTest`'s own helper, needed
  # here only for the two real-`Session` recordings above.
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
end
