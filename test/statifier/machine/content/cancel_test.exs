defmodule Statifier.Machine.Content.CancelTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Evaluator, ExecutableContent, Lowering}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.{Machine, MachineState, Parser, Validator}

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # One state per attribute/failure variant under test, each with a single
  # <cancel> in its own <onexit> - the same "one c_index per named state"
  # shape `send_test.exs` uses. `sid` is a declared datamodel root so
  # `sendidexpr` has something to read.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="bare">
      <datamodel>
          <data id="sid" expr="'dyn_send_1'"/>
      </datamodel>
      <state id="bare"><onexit><cancel sendid="send_1"/></onexit></state>
      <state id="unmatched"><onexit><cancel sendid="never_sent"/></onexit></state>
      <state id="sendidexpr"><onexit><cancel sendidexpr="sid"/></onexit></state>
      <state id="fail_sendidexpr"><onexit><cancel sendidexpr="nope"/></onexit></state>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp idx(machine, name), do: machine |> Machine.index(name) |> elem(1)

  defp cancel_node(machine, name) do
    [block] = Machine.at(machine, idx(machine, name)).onexit
    [c_index] = block.content
    Machine.content(machine, c_index)
  end

  defp machine_state(m, opts \\ []) do
    {ms, _effects} = m |> MachineState.new(opts) |> Datamodel.initialize()
    ms
  end

  defp context(ms, owner \\ {:onexit, 0, 0}) do
    %Context{machine_state: ms, owner: owner, datamodel_context: Evaluator.context(ms)}
  end

  describe "execute/2 - sendid and sendidexpr" do
    # sabotage: `execute/2`'s effect literal builds `send_id:
    # Integer.to_string(node.c_index)` instead of `send_id: send_id` -> this
    # test's `send_id: "send_1"` assertion reddens (also reddens the
    # "unmatched send_id" and "sendidexpr evaluates" tests below, since all
    # three read `send_id` off the same effect literal).
    test "a static sendid resolves onto Effect.Cancel" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "bare")

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{send_id: "send_1"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: see the note above `a static sendid resolves onto
    # Effect.Cancel` - the same `send_id:
    # Integer.to_string(node.c_index)` mutation reddens this test too,
    # proving `resolve_expr/2`'s result is what actually reaches the effect.
    test "sendidexpr evaluates against the datamodel" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "sendidexpr")

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{send_id: "dyn_send_1"}}]} =
               ExecutableContent.execute(node, context(ms))
    end
  end

  describe "execute/2 - owner and step counters" do
    # sabotage: `execute/2`'s `effect` literal has `owner: owner` changed to
    # `owner: nil` -> this test's owner round-trip assertion reddens. Proven
    # by mutation; reverted after confirming.
    test "owner and c_index round-trip onto the effect" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "bare")
      owner = {:onexit, 2, 0}

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{owner: ^owner, c_index: c_index}}]} =
               ExecutableContent.execute(node, context(ms, owner))

      assert c_index == node.c_index
    end

    # sabotage: `execute/2`'s `effect` literal has `round: machine_state.round`
    # hardcoded to `round: 0` -> this test's `round == 9` assertion reddens
    # against a machine state whose round has actually advanced past 0.
    # Reverted and confirmed green.
    test "round is stamped from machine_state.round (ADR-0046)" do
      m = machine()
      ms = %{machine_state(m) | round: 9}
      node = cancel_node(m, "bare")

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{round: 9}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # ADR-0059: `timer_counter` advances by 1 on every `<cancel>`
    # construction and is read back verbatim as the effect's `ordinal`.
    #
    # sabotage: `execute/2`'s `machine_state = %{machine_state |
    # timer_counter: machine_state.timer_counter + 1}` line is deleted (the
    # effect still reads `ordinal: machine_state.timer_counter`, off the
    # un-bumped value) -> the ordinal comes back `0` instead of `1`,
    # reddening this test. Reverted and confirmed green.
    test "timer_counter advances and is read back as ordinal" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "bare")

      assert {:ok, ctx, [{:cancel, %Effect.Cancel{ordinal: 1}}]} =
               ExecutableContent.execute(node, context(ms))

      assert ctx.machine_state.timer_counter == 1
    end

    # sabotage: `execute/2`'s effect literal stores `caller_context: nil`
    # instead of reading `machine_state.caller_context` -> the first
    # assertion reddens. ADR-0063 decision 3: `<cancel>` copies the
    # transient slot at the same site that reads the counters, the same
    # both-or-neither symmetry that gave `%Cancel{}` its `ordinal`.
    test "caller_context is copied from machine_state (ADR-0063)" do
      m = machine()
      host_context = %{trace_id: "abc"}
      ms = %{machine_state(m) | caller_context: host_context}
      node = cancel_node(m, "bare")

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{} = effect}]} =
               ExecutableContent.execute(node, context(ms))

      assert effect.caller_context == host_context

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{caller_context: nil}}]} =
               ExecutableContent.execute(node, context(machine_state(m)))
    end
  end

  describe "execute/2 - an unmatched send_id is emitted anyway" do
    # sabotage: see the note on `a static sendid resolves onto
    # Effect.Cancel` - the same `send_id: Integer.to_string(node.c_index)`
    # mutation reddens this test too, since it also asserts on `send_id`.
    # The plan is explicit that the core does nothing about a nonexistent
    # id (6.3 "SHOULD make its best attempt" belongs to `Statifier.Session`,
    # `lib/statifier/session.ex:550`), so this test's own job is to pin
    # that the effect is emitted regardless - which the mutation does not
    # touch (`{:ok, _, [{:cancel, _}]}`'s shape stays correct; only the
    # `send_id` value is wrong), demonstrated by the mutation still landing
    # on the `send_id` assertion rather than the shape assertion.
    test "a sendid matching no pending send still produces the effect" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "unmatched")

      assert {:ok, _ctx, [{:cancel, %Effect.Cancel{send_id: "never_sent"}}]} =
               ExecutableContent.execute(node, context(ms))
    end
  end

  describe "execute/2 - argument failure yields no effect" do
    # sabotage: `execute/2`'s `with` is changed to a plain `case
    # resolve_expr(...)` that ignores an `{:error, _}` and proceeds with
    # `nil` as `send_id` -> a failing `sendidexpr` would still emit
    # `{:cancel, _}` (with `send_id: nil`) instead of `{:error, _}`,
    # reddening this test's `{:error, _reason}` shape assertion. Proven by
    # mutation; reverted after confirming.
    test "a failing sendidexpr yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "fail_sendidexpr")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
    end

    # Decision 1: a `<cancel>` whose `sendidexpr` fails to resolve builds no
    # effect, so it must not advance `timer_counter` either - the bump lives
    # inside the `with` body, after `resolve_expr/2` succeeds, and this
    # file's own moduledoc states the failure path returns the bare
    # two-element `{:error, reason}` form.
    #
    # sabotage: n/a - the bump line living inside the `with` body means a
    # failed `resolve_expr/2` never reaches it, and the two-element
    # `{:error, reason}` shape has no `machine_state` slot for a bump to
    # leak through even if it did: `Statifier.Interpreter.Content.run_nodes/2`
    # (the sole caller, `lib/statifier/interpreter/content.ex`'s
    # `{:error, reason} -> {:halt, {context, ...` clause) discards to the
    # fold's pre-call context on exactly that shape, by construction. The
    # test above ("a failing sendidexpr yields {:error, _} and no effect")
    # already sabotage-covers the one mutation that could defeat this - a
    # rewrite that swallows the error and builds an effect anyway, changing
    # the return shape - so this test documents the invariant `ordinal`
    # depends on without inventing a second, unfalsifiable mutation for it.
    test "a failing sendidexpr leaves timer_counter untouched (structural: no bump on the error path)" do
      m = machine()
      ms = machine_state(m)
      node = cancel_node(m, "fail_sendidexpr")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
      assert ms.timer_counter == 0
    end
  end
end
