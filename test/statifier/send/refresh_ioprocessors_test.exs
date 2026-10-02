defmodule Statifier.Send.RefreshIoprocessorsTest do
  use ExUnit.Case, async: true

  # ADR-0075's Amendment of 2026-10-02: a host refreshes the registered
  # `_ioprocessors` entries, through `MachineState.refresh_ioprocessors/1`
  # before a resume or `Session.refresh_ioprocessors/1` on a live session.
  # Parcel delivery throughout: the Basic HTTP processor at a depot's base
  # URL, a courier processor whose location its front rotates, and a locker
  # processor that exports only `ioprocessors_entry/1`.

  alias Statifier.{MachineState, Position, Replay, Session}
  alias Statifier.Send.{BasicHTTP, Types}

  @scxml_uri "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"
  @old_depot "http://depot-a.test/basichttp"
  @new_depot "http://depot-b.test/basichttp"

  defmodule Courier do
    @moduledoc false
    # The location a parcel courier's front hands out, read from a
    # `:persistent_term` key the registration names, so a test can rotate
    # it under a live session.
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type, %{session_id: session_id, opts: opts}),
      do: %{"location" => :persistent_term.get(Keyword.fetch!(opts, :route)) <> session_id}
  end

  defmodule Locker do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type),
      do: %{
        "location" => :persistent_term.get(:statifier_refresh_test_locker_bay, "locker:bay-7")
      }
  end

  @chart """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
        <datamodel>
          <data id="depot" expr="''"/>
          <data id="courier" expr="''"/>
        </datamodel>
        <state id="waiting">
          <transition event="read" target="read">
            <assign location="depot" expr="_ioprocessors['basichttp'].location"/>
            <assign location="courier" expr="_ioprocessors['parcel:courier'].location"/>
          </transition>
          <transition event="deliver" target="delivered"/>
        </state>
        <state id="read">
          <transition event="read" target="read">
            <assign location="depot" expr="_ioprocessors['basichttp'].location"/>
            <assign location="courier" expr="_ioprocessors['parcel:courier'].location"/>
          </transition>
          <transition event="deliver" target="delivered"/>
        </state>
        <final id="delivered"/>
      </scxml>
  """

  @idle """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
        <state id="idle"/>
      </scxml>
  """

  setup do
    route = {__MODULE__, System.unique_integer([:positive])}
    :persistent_term.put(route, "courier:route-1/")
    on_exit(fn -> :persistent_term.erase(route) end)
    {:ok, machine} = Statifier.compile(@chart)
    %{route: route, machine: machine}
  end

  defp send_types(base_url_opts, route) do
    %{
      "basichttp" => {BasicHTTP, base_url_opts},
      "parcel:courier" => {Courier, route: route},
      "parcel:locker" => Locker
    }
  end

  defp start!(machine, opts) do
    {:ok, session} = Statifier.start_session(machine, opts)
    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    session
  end

  # A position persisted at the old depot, as a host stores it.
  defp persisted_at_old_depot(machine, route) do
    session = start!(machine, send_types: send_types([base_url: @old_depot], route))
    {:ok, blob} = Position.to_binary(Session.snapshot(session))
    :ok = Session.stop(session)
    blob
  end

  defp restamped(blob, machine, send_types) do
    {:ok, position} = Position.from_binary(blob, machine)
    MachineState.put_send_types(position, Types.from_send_types(send_types))
  end

  describe "MachineState.refresh_ioprocessors/1" do
    # sabotage: `refreshed_ioprocessors/3` returns `ioprocessors` unchanged
    # on success -> the basichttp location still names the old depot and
    # the equality reddens. Confirmed red and reverted.
    test "a position re-stamped with a new base URL reads the new location, and nothing else moves",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      position = restamped(blob, machine, send_types([base_url: @new_depot], route))
      sid = position.datamodel["_sessionid"]
      before = position.datamodel["_ioprocessors"]

      assert {:ok, refreshed} = MachineState.refresh_ioprocessors(position)
      after_refresh = refreshed.datamodel["_ioprocessors"]

      assert after_refresh["basichttp"] == %{"location" => @new_depot <> "/" <> sid}
      assert Map.delete(after_refresh, "basichttp") == Map.delete(before, "basichttp")

      assert Map.delete(refreshed.datamodel, "_ioprocessors") ==
               Map.delete(position.datamodel, "_ioprocessors")
    end

    # sabotage: `refreshed_ioprocessors/3`'s filter drops its
    # `ioprocessors_entry/2` export check and a `/1`-only type is rewritten
    # from the re-stamped set's entry -> the locker reads bay-8 and the
    # equality reddens. Confirmed red and reverted.
    test "the SCXML entry and a /1-only processor's entry are untouched",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      # The locker's own entry has moved since the position was persisted,
      # so the re-stamped set carries bay-8; the refresh must not use it.
      :persistent_term.put(:statifier_refresh_test_locker_bay, "locker:bay-8")
      on_exit(fn -> :persistent_term.erase(:statifier_refresh_test_locker_bay) end)
      position = restamped(blob, machine, send_types([base_url: @new_depot], route))
      before = position.datamodel["_ioprocessors"]

      {:ok, refreshed} = MachineState.refresh_ioprocessors(position)

      assert Map.take(refreshed.datamodel["_ioprocessors"], [@scxml_uri, "parcel:locker"]) ==
               Map.take(before, [@scxml_uri, "parcel:locker"])

      assert refreshed.datamodel["_ioprocessors"]["parcel:locker"] == %{
               "location" => "locker:bay-7"
             }

      assert Map.keys(refreshed.datamodel["_ioprocessors"]) == Map.keys(before)
    end

    # sabotage: `refreshed_ioprocessors/3`'s error arm answers
    # `{:ok, ioprocessors}` -> the refresh reports success and the equality
    # reddens. Confirmed red and reverted.
    test "a registration without :base_url answers the missing option and changes nothing",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      position = restamped(blob, machine, send_types([], route))

      assert MachineState.refresh_ioprocessors(position) ==
               {:error, {:missing_option, :base_url}}
    end

    # sabotage: `MachineState.refresh_ioprocessors/1`'s `send_types: nil`
    # clause drops `_ioprocessors` from the datamodel -> the binaries differ
    # and the equality reddens. Confirmed red and reverted.
    test "a position that registers nothing comes back byte-identical" do
      {:ok, machine} = Statifier.compile(@idle)
      position = MachineState.new(machine)

      assert {:ok, refreshed} = MachineState.refresh_ioprocessors(position)
      assert :erlang.term_to_binary(refreshed) == :erlang.term_to_binary(position)
    end
  end

  describe "a resume after the base URL moved" do
    # sabotage: `refresh_ioprocessors/1`'s success arm returns the
    # unrefreshed `machine_state` -> the chart reads the old depot and the
    # first equality reddens. Confirmed red and reverted.
    test "the host re-stamps and refreshes before resuming, and the chart reads the new location",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      new_types = send_types([base_url: @new_depot], route)

      {:ok, position} =
        machine |> then(&restamped(blob, &1, new_types)) |> MachineState.refresh_ioprocessors()

      session = start!(machine, resume: position, send_types: new_types)
      :ok = Session.send_event(session, "read")
      datamodel = Session.snapshot(session).datamodel

      assert datamodel["depot"] == @new_depot <> "/" <> datamodel["_sessionid"]

      # The resume default is unchanged: without the refresh, the same
      # re-stamp reads the location the position was persisted with.
      unrefreshed = start!(machine, resume: blob, send_types: new_types)
      :ok = Session.send_event(unrefreshed, "read")
      stale = Session.snapshot(unrefreshed).datamodel

      assert stale["depot"] == @old_depot <> "/" <> stale["_sessionid"]
    end

    # sabotage: `MachineState.refresh_ioprocessors/1`'s success arm returns
    # the unrefreshed `machine_state` -> the recording's anchor carries the
    # old depot, the replay reads it, and the depot equality reddens.
    # Confirmed red and reverted.
    test "a recorded session resumed from a refreshed position replays to the refreshed entries",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      new_types = send_types([base_url: @new_depot], route)

      {:ok, position} =
        machine |> then(&restamped(blob, &1, new_types)) |> MachineState.refresh_ioprocessors()

      session = start!(machine, resume: position, send_types: new_types, record: true)
      :ok = Session.send_event(session, "read")
      live = Session.snapshot(session).datamodel
      {:ok, recording} = Session.recording(session)

      assert {:ok, %{machine_state: replayed}} = Replay.run(recording)
      assert replayed.datamodel["depot"] == @new_depot <> "/" <> live["_sessionid"]
      assert replayed.datamodel["_ioprocessors"] == live["_ioprocessors"]
    end
  end

  describe "Session.refresh_ioprocessors/1" do
    # sabotage: the live success arm replies `:ok` without storing the
    # refreshed `machine_state` -> the chart reads route-1 and the equality
    # reddens. Confirmed red and reverted.
    test "a live session reads a rotated location after the call",
         %{machine: machine, route: route} do
      session = start!(machine, send_types: send_types([base_url: @old_depot], route))
      sid = Session.session_id(session)
      :persistent_term.put(route, "courier:route-2/")

      assert Session.refresh_ioprocessors(session) == :ok
      :ok = Session.send_event(session, "read")
      datamodel = Session.snapshot(session).datamodel

      assert datamodel["courier"] == "courier:route-2/" <> sid
      assert datamodel["depot"] == @old_depot <> "/" <> sid
    end

    # sabotage: the live call's error arm replies `:ok` -> the equality on
    # the answer reddens. Confirmed red and reverted.
    test "a resumed registration without :base_url answers the missing option and changes nothing",
         %{machine: machine, route: route} do
      blob = persisted_at_old_depot(machine, route)
      session = start!(machine, resume: blob, send_types: send_types([], route))
      before = Session.snapshot(session)
      :persistent_term.put(route, "courier:route-2/")

      assert Session.refresh_ioprocessors(session) == {:error, {:missing_option, :base_url}}
      assert Session.snapshot(session) == before
    end

    # sabotage: the `halted != nil` clause never matches -> the halted session
    # refreshes and answers `:ok`, and the equality reddens. Confirmed red
    # and reverted.
    test "a halted session answers :not_running", %{machine: machine, route: route} do
      session = start!(machine, send_types: send_types([base_url: @old_depot], route))
      :ok = Session.send_event(session, "deliver")
      assert Session.status(session).status == :done

      assert Session.refresh_ioprocessors(session) == {:error, :not_running}
    end

    # sabotage: the live success clause's `recording: nil` pattern is
    # widened to any recording -> the recorded session refreshes, the call
    # answers `:ok`, and the equality reddens. Confirmed red and reverted.
    test "a recorded session answers :recorded_session and changes nothing",
         %{machine: machine, route: route} do
      session =
        start!(machine, send_types: send_types([base_url: @old_depot], route), record: true)

      before = Session.snapshot(session)
      :persistent_term.put(route, "courier:route-2/")

      assert Session.refresh_ioprocessors(session) == {:error, :recorded_session}
      assert Session.snapshot(session) == before
    end

    # sabotage: `MachineState.refresh_ioprocessors/1`'s `send_types: nil`
    # clause drops `_ioprocessors` from the datamodel -> the binaries differ
    # and the equality reddens. Confirmed red and reverted.
    test "a session that registers nothing answers :ok and its position is byte-identical" do
      {:ok, machine} = Statifier.compile(@idle)
      session = start!(machine, [])
      before = Session.snapshot(session)

      assert Session.refresh_ioprocessors(session) == :ok
      assert :erlang.term_to_binary(Session.snapshot(session)) == :erlang.term_to_binary(before)
    end

    # sabotage: the nil-stamp clause of `Session.handle_call/3` is moved
    # after the recorded-session clause -> the call answers
    # `{:error, :recorded_session}` and the equality reddens. Confirmed red
    # and reverted.
    test "a recorded session that registers nothing answers :ok and its position is byte-identical" do
      {:ok, machine} = Statifier.compile(@idle)
      session = start!(machine, record: true)
      before = Session.snapshot(session)

      assert Session.refresh_ioprocessors(session) == :ok
      assert :erlang.term_to_binary(Session.snapshot(session)) == :erlang.term_to_binary(before)
    end

    # sabotage: the nil-stamp clause of `Session.handle_call/3` is moved
    # after the halted clause -> the call answers `{:error, :not_running}`
    # and the equality reddens. Confirmed red and reverted.
    test "a halted session that registers nothing answers :ok", %{machine: machine} do
      session = start!(machine, [])
      :ok = Session.send_event(session, "deliver")
      assert Session.status(session).status == :done
      before = Session.snapshot(session)

      assert Session.refresh_ioprocessors(session) == :ok
      assert :erlang.term_to_binary(Session.snapshot(session)) == :erlang.term_to_binary(before)
    end
  end
end
