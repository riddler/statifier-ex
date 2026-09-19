defmodule Statifier.Send.SendTypesPersistenceTest do
  use ExUnit.Case, async: true

  # ADR-0069's persistence consequences: `send_types` joins `routes` and
  # `invoke_types` in what the position blob drops and blanks (ADR-0064),
  # the recording keeps the session's `:send_types` map with its modules as
  # strings (ADR-0057 decision 5's rule), and replay re-stamps the snapshot
  # from that map.

  alias Statifier.{MachineState, Position, Replay}
  alias Statifier.Send.Types
  alias Statifier.Session.Recording

  defmodule SinkProcessor do
    @moduledoc false
  end

  @xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @send_types %{"myapp:sink" => SinkProcessor}

  defp compile! do
    {:ok, machine} = Statifier.compile(@xml)
    machine
  end

  defp stamped(machine) do
    machine
    |> MachineState.new()
    |> MachineState.put_send_types(Types.from_send_types(@send_types))
  end

  describe "the position blob (ADR-0064)" do
    # sabotage: `Position.to_binary/1`'s `Map.drop([:machine, :routes,
    # :invoke_types, :send_types])` loses `:send_types` -> the raw payload
    # carries the key, and the `refute` reddens. Confirmed red and reverted.
    test "to_binary/1 drops send_types from the payload" do
      assert {:ok, blob} = Position.to_binary(stamped(compile!()))

      assert {:statifier_position, 2, _identity, payload} = :erlang.binary_to_term(blob)
      refute Map.has_key?(payload, :send_types)
    end

    # sabotage: `Position.from_binary/2`'s `Map.drop([:routes, :invoke_types,
    # :send_types])` loses `:send_types` -> the hand-built payload's stale
    # value survives the decode, and the `== nil` assertion reddens.
    # Confirmed red and reverted.
    test "from_binary/2 blanks a send_types the blob carries" do
      machine = compile!()

      payload =
        machine
        |> stamped()
        |> Map.from_struct()
        |> Map.delete(:machine)

      assert %Types{} = payload.send_types

      blob =
        :erlang.term_to_binary(
          {:statifier_position, 2, Statifier.Machine.identity(machine), payload}
        )

      assert {:ok, decoded} = Position.from_binary(blob, machine)
      assert decoded.send_types == nil
    end

    # sabotage: `Position`'s `build_machine_state/2` sets `send_types:
    # :sabotage` in place of `nil` -> the imported position carries it, and
    # the `== nil` assertion reddens. Confirmed red and reverted.
    test "export/1 omits send_types and import/2 sets it nil" do
      machine = compile!()

      assert {:ok, exported} = Position.export(stamped(machine))
      refute Map.has_key?(exported, :send_types)

      assert {:ok, imported} = Position.import(machine, exported)
      assert imported.send_types == nil
    end
  end

  describe "the recording" do
    # sabotage: `Recording`'s `@normalized_opts` loses `:send_types` -> the
    # map is dropped by `Keyword.take/2`, and this assertion reddens.
    # Confirmed red and reverted.
    test "keeps a non-empty :send_types map as the session's own map" do
      recording = Recording.new(compile!(), send_types: @send_types)

      assert Keyword.fetch(Recording.opts(recording), :send_types) == {:ok, @send_types}
    end

    # sabotage: `drop_empty_send_types/1`'s `_none ->` arm returns `opts`
    # unchanged -> an empty map is kept as `send_types: %{}`, the options
    # differ from a recording made with none, and the equality reddens.
    # Confirmed red and reverted.
    test "an empty or absent :send_types records exactly what it recorded before" do
      machine = compile!()

      assert Recording.opts(Recording.new(machine, send_types: %{})) ==
               Recording.opts(Recording.new(machine, []))

      refute Keyword.has_key?(Recording.opts(Recording.new(machine, [])), :send_types)
    end

    # sabotage: `encode_opts/1`'s `Keyword.replace_lazy(:send_types,
    # &module_names/1)` line is deleted -> the blob carries the module atom,
    # and the string assertion reddens. Confirmed red and reverted.
    test "the blob writes each processor module as a string, and decoding resolves it back" do
      recording = Recording.new(compile!(), send_types: @send_types)

      assert {:ok, blob} = Recording.to_binary(recording)

      assert {:statifier_recording, _version, _chart, opts, _entries, _anchor} =
               :erlang.binary_to_term(blob)

      assert opts[:send_types] == %{"myapp:sink" => Atom.to_string(SinkProcessor)}

      assert {:ok, decoded} = Recording.from_binary(blob)
      assert Recording.opts(decoded)[:send_types] == @send_types
    end

    # sabotage: `decode_opts/1`'s key list is reduced to
    # `[:invoke_handlers]` -> the `:send_types` names are never resolved, the
    # unknown name is never reported, and the `{:error, _}` match reddens.
    # Confirmed red and reverted.
    test "an unresolvable processor module name is reported, not decoded" do
      recording = Recording.new(compile!(), send_types: @send_types)
      assert {:ok, blob} = Recording.to_binary(recording)

      {:statifier_recording, version, chart, opts, entries, anchor} =
        :erlang.binary_to_term(blob)

      missing = "Elixir.Statifier.NoSuchSendProcessorLoaded"
      opts = Keyword.put(opts, :send_types, %{"myapp:sink" => missing})

      doctored =
        :erlang.term_to_binary({:statifier_recording, version, chart, opts, entries, anchor})

      assert Recording.from_binary(doctored) == {:error, {:unknown_handler_modules, [missing]}}
    end
  end

  describe "replay re-stamps send_types from the recording" do
    # sabotage: `Replay`'s fresh branch passes `Recording.opts(recording)`
    # straight to `Interpreter.initialize/2` (the `Keyword.put(...,
    # :send_types, send_types(recording))` dropped) -> `MachineState.new/2`
    # stamps the raw map, and the equality reddens. Confirmed red and
    # reverted.
    test "a recording from a fresh start" do
      recording = Recording.new(compile!(), session_id: "sess_fresh", send_types: @send_types)

      assert {:ok, %{machine_state: machine_state}} = Replay.run(recording)
      assert machine_state.send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `Replay`'s anchored branch drops its
    # `MachineState.put_send_types/2` call -> the decoded position's `nil`
    # survives, and the equality reddens. Confirmed red and reverted.
    test "an anchored recording, whose position blob carries no send_types" do
      machine = compile!()

      {machine_state, _effects} =
        Statifier.Interpreter.initialize(machine, session_id: "sess_anchor")

      assert {:ok, anchor} = Position.to_binary(machine_state)

      recording =
        Recording.new(machine, [session_id: "sess_anchor", send_types: @send_types], anchor)

      assert {:ok, %{machine_state: replayed}} = Replay.run(recording)
      assert replayed.send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `Replay`'s `send_types/1` helper defaults a missing key to
    # `%{"sabotage" => nil}` instead of `%{}` -> a recording with no
    # declaration replays with a declared set, and the `== nil` assertion
    # reddens. Confirmed red and reverted.
    test "a recording with no :send_types replays with no declaration" do
      assert {:ok, %{machine_state: machine_state}} =
               Replay.run(Recording.new(compile!(), session_id: "sess_none"))

      assert machine_state.send_types == nil
    end
  end
end
