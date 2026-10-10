defmodule Statifier.Send.ReplaceSendTypeTest do
  use ExUnit.Case, async: true

  # ADR-0069's Amendment of 2026-10-09: `Session.replace_send_type/3`
  # replaces a running session's registration for one send type and
  # recomputes that type's `_ioprocessors` entry in the same call. The
  # library world throughout: a branch's Basic HTTP front, a hold-notice
  # processor whose desk is a registration option, and a catalog processor
  # that exports only `ioprocessors_entry/1`.

  alias Statifier.Send.BasicHTTP
  alias Statifier.Session

  @old_front "http://branch-north.test/basichttp"
  @new_front "http://branch-south.test/basichttp"

  defmodule Notice do
    @moduledoc false
    # A hold-ready notice to a patron, sent from the desk the registration
    # names; `perform/2` reports the desk to the test process the
    # registration names, so a test sees which registration delivered.
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, event, %{opts: opts}),
      do:
        {:ok,
         [
           {:handler, __MODULE__,
            {Keyword.fetch!(opts, :notify), Keyword.fetch!(opts, :desk), event.name}}
         ]}

    @impl Statifier.Send.Processor
    def cancel(cancel, %{opts: opts}),
      do:
        {:ok,
         [
           {:handler, __MODULE__,
            {Keyword.fetch!(opts, :notify), Keyword.fetch!(opts, :desk),
             {:cancel, cancel.send_id}}}
         ]}

    @impl Statifier.Send.Processor
    def perform({notify, desk, name}, _ctx) do
      send(notify, {__MODULE__, desk, name})
      :ok
    end

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type, %{session_id: session_id, opts: opts}),
      do: %{"location" => "notice:" <> Keyword.fetch!(opts, :desk) <> "/" <> session_id}
  end

  defmodule LateNotice do
    @moduledoc false
    # A second notice processor, so a test can replace the module and see
    # which one a `<cancel>` reaches.
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(cancel, %{opts: opts}),
      do:
        {:ok,
         [{:handler, __MODULE__, {Keyword.fetch!(opts, :notify), {:cancel, cancel.send_id}}}]}

    @impl Statifier.Send.Processor
    def perform({notify, what}, _ctx) do
      send(notify, {__MODULE__, what})
      :ok
    end

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type, _context), do: %{"location" => "late-notice:desk"}
  end

  defmodule JammedNotice do
    @moduledoc false
    # A notice processor whose entry raises, so a replacement with it fails
    # after the processor has accepted the registration.
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type, _context), do: raise("notice desk jammed")
  end

  defmodule Catalog do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type), do: %{"shelf" => "catalog:main"}
  end

  defmodule AnnexCatalog do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(_type), do: %{"shelf" => "catalog:annex"}
  end

  @chart """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="holding">
        <datamodel>
          <data id="front" expr="''"/>
          <data id="desk" expr="''"/>
        </datamodel>
        <state id="holding">
          <transition event="read">
            <assign location="front" expr="_ioprocessors['basichttp'].location"/>
            <assign location="desk" expr="_ioprocessors['myapp:notice'].location"/>
          </transition>
          <transition event="ready">
            <send type="myapp:notice" event="hold.ready" target="patron-42"/>
          </transition>
          <transition event="remind">
            <send id="reminder" type="myapp:notice" event="hold.reminder" target="patron-42" delay="60s"/>
          </transition>
          <transition event="unremind">
            <cancel sendid="reminder"/>
          </transition>
          <transition event="collect" target="collected"/>
        </state>
        <final id="collected"/>
      </scxml>
  """

  @idle """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
        <state id="idle"/>
      </scxml>
  """

  setup do
    {:ok, machine} = Statifier.compile(@chart)
    %{machine: machine}
  end

  defp send_types(desk) do
    %{
      "basichttp" => {BasicHTTP, base_url: @old_front},
      "myapp:notice" => {Notice, desk: desk, notify: self()},
      "myapp:catalog" => Catalog
    }
  end

  defp start!(machine, opts) do
    {:ok, session} = Statifier.start_session(machine, opts)
    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    session
  end

  defp ioprocessors(session), do: Session.snapshot(session).datamodel["_ioprocessors"]

  defp position(session), do: :erlang.term_to_binary(Session.snapshot(session))

  # A call that exits the caller answers `{:exited, reason}` here, so a
  # mutant that crashes the session reddens an assertion rather than the
  # test process.
  defp replace(session, type, registration) do
    Session.replace_send_type(session, type, registration)
  catch
    :exit, reason -> {:exited, reason}
  end

  describe "a replacement the session accepts" do
    # sabotage: the success arm of the `{:replace_send_type, ...}` clause
    # replies `:ok` without storing the new `machine_state` -> the entry and
    # the chart's read keep the old front, and the equalities redden.
    # Confirmed red and reverted.
    test "the Basic HTTP entry carries the new base URL, and the chart reads it",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      sid = Session.session_id(session)
      before = ioprocessors(session)

      assert Session.replace_send_type(session, "basichttp", {BasicHTTP, base_url: @new_front}) ==
               :ok

      after_call = ioprocessors(session)
      assert after_call["basichttp"] == %{"location" => @new_front <> "/" <> sid}
      assert Map.delete(after_call, "basichttp") == Map.delete(before, "basichttp")

      :ok = Session.send_event(session, "read")
      assert Session.snapshot(session).datamodel["front"] == @new_front <> "/" <> sid
    end

    # sabotage: the success arm stores the new `machine_state` but keeps
    # the session's old `send_types` map -> the notice is delivered from
    # desk-1 and the `assert_receive` on desk-2 reddens. Confirmed red and
    # reverted.
    test "a later send of the type is delivered through the new registration",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      sid = Session.session_id(session)

      assert Session.replace_send_type(
               session,
               "myapp:notice",
               {Notice, desk: "desk-2", notify: self()}
             ) == :ok

      assert ioprocessors(session)["myapp:notice"] == %{"location" => "notice:desk-2/" <> sid}

      :ok = Session.send_event(session, "ready")
      assert_receive {Notice, "desk-2", "hold.ready"}, 5_000
      refute_received {Notice, "desk-1", _name}
    end

    # sabotage: `Statifier.Send.Types.replace/3` keeps the type's old
    # `entries` value -> the catalog entry still reads catalog:main and the
    # equality reddens. Confirmed red and reverted.
    test "a processor exporting only ioprocessors_entry/1 has its new module's entry",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      assert ioprocessors(session)["myapp:catalog"] == %{"shelf" => "catalog:main"}

      assert Session.replace_send_type(session, "myapp:catalog", AnnexCatalog) == :ok
      assert ioprocessors(session)["myapp:catalog"] == %{"shelf" => "catalog:annex"}
    end
  end

  describe "what a replacement does not carry over" do
    # sabotage: the success arm of the `{:replace_send_type, ...}` clause
    # keeps the session's old `send_types` map -> the cancel is planned
    # through `Notice` with desk-1, and the `assert_receive` on
    # `LateNotice` reddens. Confirmed red and reverted.
    test "a delayed send held before the call is cancelled through the new registration",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      :ok = Session.send_event(session, "remind")
      assert_receive {Notice, "desk-1", "hold.reminder"}, 5_000

      assert Session.replace_send_type(session, "myapp:notice", {LateNotice, notify: self()}) ==
               :ok

      :ok = Session.send_event(session, "unremind")
      assert_receive {LateNotice, {:cancel, "reminder"}}, 5_000
      refute_received {Notice, _desk, {:cancel, _send_id}}
    end

    # sabotage: `accepted_registration/2` refuses a module that does not
    # load -> the call answers an `:invalid_registration` error instead of
    # `:ok`, and the equality reddens. Confirmed red and reverted.
    @tag :capture_log
    test "an atom that names no module is stored, and the next send of the type exits the session",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      ref = Process.monitor(session)

      assert replace(session, "myapp:notice", :no_such_notice_processor) == :ok
      assert ioprocessors(session)["myapp:notice"] == %{}

      Session.send_event(session, "ready")
      assert_receive {:DOWN, ^ref, :process, ^session, {:undef, _stacktrace}}, 5_000
    end
  end

  describe "a replacement the session refuses, changing nothing" do
    # sabotage: the `halted != nil` clause of `{:replace_send_type, ...}`
    # never matches -> the halted session replaces the registration and
    # answers `:ok`, and the equality reddens. Confirmed red and reverted.
    test "a halted session answers :not_running", %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      :ok = Session.send_event(session, "collect")
      assert Session.status(session).status == :done
      before = position(session)

      assert replace(session, "basichttp", {BasicHTTP, base_url: @new_front}) ==
               {:error, :not_running}

      assert position(session) == before
    end

    # sabotage: the `recording != nil` clause of `{:replace_send_type, ...}`
    # never matches -> the recorded session replaces the registration and
    # answers `:ok`, and the equality reddens. Confirmed red and reverted.
    test "a recorded session answers :recorded_session", %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"), record: true)
      before = position(session)

      assert replace(session, "basichttp", {BasicHTTP, base_url: @new_front}) ==
               {:error, :recorded_session}

      assert position(session) == before
    end

    # sabotage: `registered_send_type/2` answers `:ok` for every type ->
    # the unknown type is stored and the call answers `:ok`, and the
    # equality reddens. Confirmed red and reverted.
    test "a type the session never registered answers :unknown_send_type",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      before = position(session)

      assert replace(session, "myapp:courier", Catalog) ==
               {:error, {:unknown_send_type, "myapp:courier"}}

      assert position(session) == before
    end

    # sabotage: `registered_send_type/2` answers `:ok` for every type ->
    # the replace step is asked of a session stamped with no send types and
    # exits it, and the equality on the answer reddens. Confirmed red and
    # reverted.
    test "a session that registers nothing answers :unknown_send_type" do
      {:ok, machine} = Statifier.compile(@idle)
      session = start!(machine, [])
      before = position(session)

      assert replace(session, "myapp:notice", Catalog) ==
               {:error, {:unknown_send_type, "myapp:notice"}}

      assert position(session) == before
    end

    # sabotage: `accepted_registration/2` answers `:ok` for every
    # registration -> Basic HTTP's entry raises on the missing option and
    # the call answers an `:ioprocessors_entry` error instead, and the
    # equality reddens. Confirmed red and reverted.
    test "a registration the processor refuses answers as start_link/2 spells it",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      before = position(session)

      assert replace(session, "basichttp", BasicHTTP) ==
               {:error,
                {:send_types, {:invalid_registration, "basichttp", {:missing_option, :base_url}}}}

      assert position(session) == before
    end

    # sabotage: `MachineState.replace_send_type/3` loses its `rescue` -> the
    # entry's raise exits the session, and the equality on the answer
    # reddens. Confirmed red and reverted.
    # sabotage: the `{:replace_send_type, ...}` clause stores the new
    # `send_types` map before the replace step answers -> the refused
    # registration stays and the next notice reaches JammedNotice, so the
    # `assert_receive` on desk-1 reddens. Confirmed red and reverted.
    test "an entry that raises is answered, and the session keeps its registration and position",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))
      before = position(session)

      assert replace(session, "myapp:notice", JammedNotice) ==
               {:error,
                {:ioprocessors_entry, "myapp:notice",
                 %RuntimeError{message: "notice desk jammed"}}}

      assert Process.alive?(session)
      assert position(session) == before

      :ok = Session.send_event(session, "ready")
      assert_receive {Notice, "desk-1", "hold.ready"}, 5_000
    end

    # sabotage: the guard on `replace_send_type/3` is dropped -> the
    # malformed registration reaches the session, which exits on it, and
    # the equality on the answer reddens. Confirmed red and reverted.
    test "a registration that is not a module or {module, opts} raises in the caller",
         %{machine: machine} do
      session = start!(machine, send_types: send_types("desk-1"))

      answer =
        try do
          Session.replace_send_type(session, "myapp:notice", {Notice, "desk-2"})
        rescue
          error in FunctionClauseError -> {:raised, error.module, error.function}
        catch
          :exit, _reason -> :exited
        end

      assert answer == {:raised, Session, :replace_send_type}
      assert Process.alive?(session)
    end
  end
end
