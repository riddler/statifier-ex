defmodule Statifier.Send.RegistrationOptionsTest do
  use ExUnit.Case, async: true

  # ADR-0075 decisions 3 and 8 (point b): a `:send_types` value may be
  # `{module, opts}`. The registered set keeps each type's module and
  # options, `_ioprocessors` asks the optional `ioprocessors_entry/2` with
  # the session id, the planner hands the options to a `{module, opts}`
  # registration's callbacks under `:opts` (a bare module's context is
  # unchanged), the recording writes the options as strings, and
  # `test_scxml/5` takes a registration.

  import Statifier.Testing.Case, only: [test_scxml: 5]

  alias Statifier.Effect.{Cancel, Send, SendDelayed}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Send.Types
  alias Statifier.Session.{Effects, Recording}

  defmodule Echo do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, ctx), do: {:ok, [{:handler, __MODULE__, {:deliver, ctx}}]}

    @impl Statifier.Send.Processor
    def cancel(_cancel, ctx), do: {:ok, [{:handler, __MODULE__, {:cancel, ctx}}]}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(type), do: %{"type" => type}

    @impl Statifier.Send.Processor
    def ioprocessors_entry("myapp:atom", _context), do: %{"k" => %{bad: 1}}

    def ioprocessors_entry(type, %{session_id: session_id, opts: opts}),
      do: %{"at" => "#{Keyword.get(opts, :prefix, "none")}/#{type}/#{session_id}"}
  end

  defmodule OnlyOne do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def ioprocessors_entry(type), do: %{"only" => type}
  end

  defp machine do
    {:ok, machine} =
      Statifier.compile("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <state id="s"/>
          </scxml>
      """)

    machine
  end

  describe "the registered set" do
    # sabotage: `from_send_types/1` stores `processors: %{}` -> the equality
    # reddens. Confirmed red and reverted.
    test "keeps each type's module and options, a bare module's options []" do
      assert %Types{processors: processors} =
               Types.from_send_types(%{"myapp:a" => {Echo, prefix: "p"}, "myapp:b" => Echo})

      assert processors == %{"myapp:a" => {Echo, [prefix: "p"]}, "myapp:b" => {Echo, []}}
    end
  end

  describe "_ioprocessors through ioprocessors_entry/2" do
    # sabotage: `session_entry/5` passes `opts: []` whatever the registration
    # carries -> the prefix reads "none" and the equality reddens. Confirmed
    # red and reverted.
    test "a module exporting /2 is asked with the session id and the options" do
      types = Types.from_send_types(%{"myapp:a" => {Echo, prefix: "p"}, "myapp:b" => Echo})
      entries = SystemVariables.initial(machine(), "sess_x", types)["_ioprocessors"]

      assert entries["myapp:a"] == %{"at" => "p/myapp:a/sess_x"}
      assert entries["myapp:b"] == %{"at" => "none/myapp:b/sess_x"}
    end

    # sabotage: `session_entry/5` answers `%{}` for a module without `/2`
    # instead of its `/1` entry -> the entry reads `%{}` and the equality
    # reddens. Confirmed red and reverted.
    test "a module exporting only /1 gets its /1 entry" do
      types = Types.from_send_types(%{"myapp:one" => {OnlyOne, x: 1}})

      assert SystemVariables.initial(machine(), "sess_x", types)["_ioprocessors"]["myapp:one"] ==
               %{"only" => "myapp:one"}
    end

    # sabotage: `Types.session_entry!/3` returns the entry unchecked -> the
    # atom-keyed map is accepted and `assert_raise` reddens. Confirmed red
    # and reverted.
    test "an entry from /2 must be string-keyed" do
      types = Types.from_send_types(%{"myapp:atom" => Echo})

      assert_raise ArgumentError, ~r/string-keyed at every level/, fn ->
        SystemVariables.initial(machine(), "sess_x", types)
      end
    end
  end

  describe "the plan context a processor's callbacks receive" do
    defp context(send_types) do
      %{
        session_id: "sess_x",
        invoke_types: nil,
        invoke_handlers: %{},
        invocation_types: %{},
        send_types: Types.from_send_types(send_types),
        send_processors: send_types
      }
    end

    defp delayed(type),
      do: %SendDelayed{
        event: "e",
        type: type,
        target: "t",
        send_id: "id",
        delay_ms: 10,
        macrostep: 1,
        microstep: 1,
        round: 0,
        ordinal: 1
      }

    defp cancel,
      do: %Cancel{send_id: "id", macrostep: 1, microstep: 2, round: 0, ordinal: 2}

    # sabotage: `processor_for/2` drops the options (answers `{module,
    # context}` for a pair too) -> `deliver/3` sees no `:opts` and the match
    # reddens. Confirmed red and reverted.
    test "a {module, opts} registration adds :opts to deliver/3's and cancel/2's context" do
      ctx = context(%{"myapp:a" => {Echo, prefix: "p"}})

      assert [
               {:notify, _send},
               {:handler, Echo, {:deliver, %{opts: [prefix: "p"]}}},
               {:notify, _cancel},
               {:cancel_timers, "id"},
               {:handler, Echo, {:cancel, %{opts: [prefix: "p"]}}}
             ] = Effects.plan([{:send_delayed, delayed("myapp:a")}, {:cancel, cancel()}], ctx)
    end

    # sabotage: `processor_for/2` puts `opts: []` for a bare module too ->
    # the context gains a key and the equality reddens. Confirmed red and
    # reverted.
    test "a bare-module registration's context is the plan context unchanged" do
      ctx = context(%{"myapp:b" => Echo})
      send = %Send{event: "e", type: "myapp:b", target: "t", macrostep: 1, microstep: 1, round: 0}

      assert [{:notify, _send}, {:handler, Echo, {:deliver, received}}] =
               Effects.plan([{:send, send}], ctx)

      assert received == ctx
    end
  end

  describe "the recording" do
    defp recorded(send_types) do
      {:ok, machine} =
        Statifier.compile("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s"/>
            </scxml>
        """)

      Recording.new(machine, send_types: send_types)
    end

    # sabotage: `option_name/1`'s atom clause writes the atom itself -> the
    # blob carries the module atom, and the match on the written options
    # reddens. Confirmed red and reverted.
    test "writes a registration's options as strings and reads them back" do
      send_types = %{"myapp:a" => {Echo, prefix: "p", via: OnlyOne, on: true}, "myapp:b" => Echo}
      assert {:ok, blob} = Recording.to_binary(recorded(send_types))

      {_tag, _version, _chart, opts, _entries, _anchor} = :erlang.binary_to_term(blob)
      written = Keyword.fetch!(opts, :send_types)["myapp:a"]
      refute match?({Echo, _opts}, written)
      assert {_name, [{"prefix", "p"}, {"via", {:atom, _via}}, {"on", true}]} = written

      assert {:ok, decoded} = Recording.from_binary(blob)
      assert Keyword.fetch!(Recording.opts(decoded), :send_types) == send_types
    end

    # sabotage: `resolve_option/2` keeps an unresolved key without adding it
    # to `missing` -> the blob decodes and the match reddens. Confirmed red
    # and reverted.
    test "an option name this node does not know is reported like a module" do
      {:ok, blob} = Recording.to_binary(recorded(%{"myapp:a" => {Echo, prefix: "p"}}))
      {tag, version, chart, opts, entries, anchor} = :erlang.binary_to_term(blob)

      doctored =
        Keyword.put(opts, :send_types, %{
          "myapp:a" => {Atom.to_string(Echo), [{"no_such_option_name_x", "v"}]}
        })

      blob = :erlang.term_to_binary({tag, version, chart, doctored, entries, anchor})

      assert Recording.from_binary(blob) ==
               {:error, {:unknown_handler_modules, ["no_such_option_name_x"]}}
    end
  end

  describe "Statifier.Testing.Case.test_scxml/5's :send_types option" do
    # sabotage: `drive_through_session/4` drops the `:send_types` option ->
    # the session registers nothing, the send is unsupported, and the chart
    # reaches `fail` on error.execution. Confirmed red and reverted.
    test "starts the session with the registration" do
      test_scxml(
        """
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="myapp:only" event="e" target="t"/>
                  <raise event="sent"/>
                </onentry>
                <transition event="sent" target="pass"/>
                <transition event="error.execution" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """,
        "a registered send",
        ["pass"],
        [],
        send_types: %{"myapp:only" => OnlyOne}
      )
    end
  end
end
