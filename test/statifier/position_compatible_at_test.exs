defmodule Statifier.PositionCompatibleAtTest do
  @moduledoc """
  `Statifier.Position.compatible_at?/3`: whether one execution's exported
  position is untouched by the edit between two compiled charts (ADR-0072
  decisions 4 and 6). Every chart is in the library world (patron, copy,
  loan, hold, branch). Each position is a real one, driven by
  `Statifier.initialize/2` and `Statifier.send_event/2` and exported with
  `Statifier.Position.export/1`, except where a test changes one field of
  that export to isolate the condition it checks. Each edit is made in
  memory from the chart above it, so the edit is the only difference the
  answer can see.
  """

  use ExUnit.Case, async: true

  alias Statifier.Position

  # The record's worked example: a hold's execution waits in
  # `awaiting_pickup` with its pickup timer pending.
  @hold """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="routing">
          <datamodel>
              <data id="copy_id" expr="'c-1'"/>
          </datamodel>
          <state id="routing">
              <transition event="copy.routed" target="awaiting_pickup"/>
          </state>
          <state id="awaiting_pickup">
              <onentry>
                  <send type="library:timer" target="hold" event="pickup.expired" id="pickup" delay="7d"/>
              </onentry>
              <onexit>
                  <cancel sendid="pickup"/>
              </onexit>
              <transition event="copy.collected" target="collected"/>
              <transition event="pickup.expired" target="expired"/>
          </state>
          <final id="collected"/>
          <final id="expired"/>
      </scxml>
  """

  # A hold whose wait sits inside a compound `on_hold` state, so the
  # waiting execution's configuration holds an ancestor with a transition
  # of its own: a patron may withdraw the hold from anywhere inside it.
  @nested_hold """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="on_hold">
          <state id="on_hold" initial="queued">
              <state id="queued">
                  <transition event="copy.available" target="awaiting_pickup"/>
              </state>
              <state id="awaiting_pickup">
                  <transition event="copy.collected" target="collected"/>
              </state>
              <transition event="hold.withdrawn" target="withdrawn"/>
          </state>
          <final id="collected"/>
          <final id="withdrawn"/>
      </scxml>
  """

  # A loan that can be disputed from anywhere in `active`, and resumes at
  # the recorded sub-state through the shallow history `h` once the
  # dispute is resolved.
  @loan """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="active">
          <state id="active" initial="on_loan">
              <history id="h" type="shallow">
                  <transition target="on_loan"/>
              </history>
              <state id="on_loan">
                  <transition event="loan.due_soon" target="due_soon"/>
              </state>
              <state id="due_soon">
                  <transition event="loan.due" target="returned"/>
              </state>
              <transition event="copy.disputed" target="held_for_review"/>
          </state>
          <state id="held_for_review">
              <transition event="dispute.resolved" target="h"/>
          </state>
          <final id="returned"/>
      </scxml>
  """

  # A hold whose pickup and overdue notice run as two regions of one
  # parallel state.
  @parallel_hold """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="ready">
          <parallel id="ready">
              <state id="pickup">
                  <transition event="copy.collected" target="collected"/>
              </state>
              <state id="notice">
                  <transition event="notice.sent" target="collected"/>
              </state>
          </parallel>
          <final id="collected"/>
      </scxml>
  """

  defp chart(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # Drives a fresh execution of `machine` through `events` and exports it.
  defp exported(machine, events) do
    {machine_state, _effects} = Statifier.initialize(machine)

    machine_state =
      Enum.reduce(events, machine_state, fn event, acc ->
        {:ok, acc, _effects} = Statifier.send_event(acc, event)
        acc
      end)

    {:ok, exported} = Position.export(machine_state)
    exported
  end

  # Rewrites `xml`, failing loudly when `pattern` is not in it, so an edit
  # that silently did nothing cannot pass for "no difference".
  defp edit(xml, pattern, replacement) do
    assert String.contains?(xml, pattern), "edit pattern not found: #{pattern}"
    String.replace(xml, pattern, replacement, global: false)
  end

  # Rewrites the run of `tags` in `xml`, one tag per line with any
  # whitespace between them, failing loudly when the run is not in it.
  defp edit_block(xml, tags, replacement) do
    pattern = tags |> Enum.map_join("\\s*", &Regex.escape/1) |> Regex.compile!()
    assert Regex.match?(pattern, xml), "edit block not found: #{Enum.join(tags, " ")}"
    Regex.replace(pattern, xml, replacement, global: false)
  end

  defp waiting_hold, do: exported(chart(@hold), ["copy.routed"])

  defp disputed_loan, do: exported(chart(@loan), ["loan.due_soon", "copy.disputed"])

  describe "the compatible edit" do
    # sabotage: `outgoing_surface/2` compares the transitions' `location`
    # structs instead of their slices (every offset below the new
    # `in_transfer` state and the new `routing` transition moved) -> red
    test "a hold waiting in awaiting_pickup is compatible across an edit adding an unrelated state" do
      exported = waiting_hold()
      assert exported.configuration == MapSet.new(["awaiting_pickup"])

      to =
        @hold
        |> edit(
          ~s(<transition event="copy.routed" target="awaiting_pickup"/>),
          ~s(<transition event="copy.routed" target="awaiting_pickup"/>
                <transition event="copy.transferred" target="in_transfer"/>)
        )
        |> edit(
          ~s(<final id="collected"/>),
          ~s(<state id="in_transfer">
                <transition event="copy.routed" target="awaiting_pickup"/>
            </state>
            <final id="collected"/>)
        )

      assert Position.compatible_at?(chart(@hold), chart(to), exported)
    end

    # sabotage: `compatible_at?/3`'s success arm answers `false` when
    # `from_machine` and `to_machine` are the same chart -> red
    test "a chart is compatible with itself at a real position" do
      assert Position.compatible_at?(chart(@hold), chart(@hold), waiting_hold())
    end

    # sabotage: `same_state?/3` compares every state of the chart instead
    # of the active ones -> red (`routing`'s transition changed)
    test "a changed transition on a state the execution is not in leaves it compatible" do
      to =
        edit(
          @hold,
          ~s(<transition event="copy.routed" target="awaiting_pickup"/>),
          ~s(<transition event="copy.routed" target="collected"/>)
        )

      assert Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `outgoing_surface/2` also slices the state's `<onentry>`
    # blocks -> red
    test "a changed onentry on the active state leaves it compatible: it already executed" do
      to = edit(@hold, ~s(delay="7d"), ~s(delay="10d"))

      assert Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end
  end

  describe "the active state's own surface" do
    # sabotage: `outgoing_surface/2` drops its `transitions` list -> red
    test "a changed transition target on the active state is not compatible" do
      to =
        edit(
          @hold,
          ~s(<transition event="pickup.expired" target="expired"/>),
          ~s(<transition event="pickup.expired" target="collected"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `outgoing_surface/2` drops its `onexit` list -> red
    test "a changed onexit on the active state is not compatible" do
      to =
        edit(
          @hold,
          ~s(<cancel sendid="pickup"/>),
          ~s(<cancel sendid="pickup"/>
                <log label="hold" expr="'pickup window closed'"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `outgoing_surface/2` drops its `invoke` list -> red
    test "an invoke added to the active state is not compatible" do
      to =
        edit(
          @hold,
          ~s(<transition event="copy.collected" target="collected"/>),
          ~s(<invoke type="library:notice" id="pickup_notice"/>
              <transition event="copy.collected" target="collected"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `outgoing_surface/2` compares the transitions as a sorted
    # list (a multiset) instead of in document order -> red
    test "reordered transitions on the active state are not compatible" do
      to =
        edit_block(
          @hold,
          [
            ~s(<transition event="copy.collected" target="collected"/>),
            ~s(<transition event="pickup.expired" target="expired"/>)
          ],
          ~s(<transition event="pickup.expired" target="expired"/>
                      <transition event="copy.collected" target="collected"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end
  end

  describe "the ancestor case" do
    # sabotage: `compatible_at?/3` runs `same_state?/3` only over the
    # atomic states of the configuration -> red
    test "a changed transition on an ancestor of the active state is not compatible" do
      exported = exported(chart(@nested_hold), ["copy.available"])
      assert exported.configuration == MapSet.new(["on_hold", "awaiting_pickup"])

      to =
        edit(
          @nested_hold,
          ~s(<transition event="hold.withdrawn" target="withdrawn"/>),
          ~s(<transition event="hold.withdrawn" target="collected"/>)
        )

      refute Position.compatible_at?(chart(@nested_hold), chart(to), exported)
    end

    # sabotage: `outgoing_surface/2` also compares the state's whole slice
    # (the new sibling sits inside the ancestor) -> red
    test "an unchanged ancestor with a new sibling state is compatible" do
      exported = exported(chart(@nested_hold), ["copy.available"])

      to =
        edit(
          @nested_hold,
          ~s(<transition event="hold.withdrawn" target="withdrawn"/>),
          ~s(<state id="in_transfer">
                  <transition event="copy.available" target="awaiting_pickup"/>
              </state>
              <transition event="hold.withdrawn" target="withdrawn"/>)
        )

      assert Position.compatible_at?(chart(@nested_hold), chart(to), exported)
    end
  end

  describe "the legal configuration" do
    # sabotage: `same_state?/3` skips its `parent_id/2` comparison and
    # `legal_member?/3`'s compound arm answers true -> red
    test "an active state moved under another parent is not compatible" do
      exported = exported(chart(@nested_hold), ["copy.available"])

      to =
        @nested_hold
        |> edit_block(
          [
            ~s(<state id="awaiting_pickup">),
            ~s(<transition event="copy.collected" target="collected"/>),
            ~s(</state>)
          ],
          ""
        )
        |> edit(
          ~s(<final id="collected"/>),
          ~s(<state id="awaiting_pickup">
              <transition event="copy.collected" target="collected"/>
          </state>
          <final id="collected"/>)
        )

      refute Position.compatible_at?(chart(@nested_hold), chart(to), exported)
    end

    # sabotage: `legal_member?/3`'s compound arm answers true and
    # `legal_configuration?/2` skips its "one or more atomic states" rule
    # -> red
    test "an active state that becomes compound is not compatible" do
      to =
        edit(
          @hold,
          ~s(<transition event="copy.collected" target="collected"/>),
          ~s(<state id="awaiting_shelf"/>
              <transition event="copy.collected" target="collected"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `same_state?/3` skips its `kind` comparison -> red
    test "an active state whose kind changes is not compatible" do
      to =
        @hold
        |> edit(~s(<state id="awaiting_pickup">), ~s(<parallel id="awaiting_pickup">))
        |> edit_block(
          [~s(<transition event="pickup.expired" target="expired"/>), ~s(</state>)],
          ~s(<transition event="pickup.expired" target="expired"/>
                </parallel>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `legal_member?/3`'s parallel arm answers true without
    # checking the regions -> red
    test "a region added to an active parallel state is not compatible" do
      exported = exported(chart(@parallel_hold), [])
      assert exported.configuration == MapSet.new(["ready", "pickup", "notice"])

      to =
        edit(
          @parallel_hold,
          ~s(</parallel>),
          ~s(<state id="renewal_check"/>
          </parallel>)
        )

      refute Position.compatible_at?(chart(@parallel_hold), chart(to), exported)
    end

    # sabotage: `legal_member?/3`'s compound arm answers true without
    # counting the children -> red
    test "a hand-edited configuration holding two children of one compound state is not compatible" do
      machine = chart(@nested_hold)
      exported = exported(machine, ["copy.available"])
      two_children = %{exported | configuration: MapSet.put(exported.configuration, "queued")}

      refute Position.compatible_at?(machine, machine, two_children)
    end

    # sabotage: `legal_member?/3`'s last arm answers true (the root is a
    # non-atomic member) -> red
    test "a hand-edited configuration holding two children of the root is not compatible" do
      machine = chart(@hold)
      two_roots = %{waiting_hold() | configuration: MapSet.new(["awaiting_pickup", "collected"])}

      refute Position.compatible_at?(machine, machine, two_roots)
    end

    # sabotage: `legal_configuration?/2` drops its refusal of a history
    # member -> red
    test "a hand-edited configuration holding a history pseudo-state is not compatible" do
      machine = chart(@loan)
      exported = exported(machine, [])
      with_history = %{exported | configuration: MapSet.put(exported.configuration, "h")}

      refute Position.compatible_at?(machine, machine, with_history)
    end
  end

  describe "the history case" do
    # sabotage: `same_history?/3` answers false for every entry -> red
    test "a recorded history value that still resolves under its parent is compatible" do
      exported = disputed_loan()
      assert exported.configuration == MapSet.new(["held_for_review"])
      assert exported.history_values == %{"h" => MapSet.new(["due_soon"])}

      to =
        edit(
          @loan,
          ~s(<final id="returned"/>),
          ~s(<state id="in_transfer"/>
          <final id="returned"/>)
        )

      assert Position.compatible_at?(chart(@loan), chart(to), exported)
    end

    # sabotage: `same_history?/3` skips its `history_type` comparison -> red
    test "a history whose type changes is not compatible" do
      to = edit(@loan, ~s(type="shallow"), ~s(type="deep"))

      refute Position.compatible_at?(chart(@loan), chart(to), disputed_loan())
    end

    # sabotage: `same_history?/3` skips its members' descendant check -> red
    test "a recorded member moved out from under the history's parent is not compatible" do
      to =
        @loan
        |> edit_block(
          [
            ~s(<state id="due_soon">),
            ~s(<transition event="loan.due" target="returned"/>),
            ~s(</state>)
          ],
          ""
        )
        |> edit(
          ~s(<final id="returned"/>),
          ~s(<state id="due_soon">
              <transition event="loan.due" target="returned"/>
          </state>
          <final id="returned"/>)
        )

      refute Position.compatible_at?(chart(@loan), chart(to), disputed_loan())
    end

    # sabotage: `same_history?/3` skips its parent-id comparison -> red
    # (`lending` wraps the recorded member too, so only the parent id differs)
    test "a history moved under another parent is not compatible" do
      to =
        @loan
        |> edit_block(
          [
            ~s(<history id="h" type="shallow">),
            ~s(<transition target="on_loan"/>),
            ~s(</history>)
          ],
          ~s(<state id="lending" initial="on_loan">
                      <history id="h" type="shallow">
                          <transition target="on_loan"/>
                      </history>)
        )
        |> edit(
          ~s(<transition event="copy.disputed" target="held_for_review"/>),
          ~s(</state>
              <transition event="copy.disputed" target="held_for_review"/>)
        )

      refute Position.compatible_at?(chart(@loan), chart(to), disputed_loan())
    end

    # sabotage: `same_history?/3` skips its `kind == :history` checks and
    # its `history_type` comparison -> red
    test "a recorded key that is no longer a history pseudo-state is not compatible" do
      to =
        edit_block(
          @loan,
          [
            ~s(<history id="h" type="shallow">),
            ~s(<transition target="on_loan"/>),
            ~s(</history>)
          ],
          ~s(<state id="h"/>)
        )

      refute Position.compatible_at?(chart(@loan), chart(to), disputed_loan())
    end
  end

  describe "the states-to-invoke case" do
    # sabotage: `compatible_at?/3` drops its `states_to_invoke` emptiness
    # check -> red
    test "a position with a state waiting for its invoke pass is not compatible" do
      machine = chart(@hold)
      exported = waiting_hold()
      assert exported.states_to_invoke == MapSet.new()
      assert Position.compatible_at?(machine, machine, exported)

      mid_macrostep = %{exported | states_to_invoke: MapSet.new(["awaiting_pickup"])}

      refute Position.compatible_at?(machine, machine, mid_macrostep)
    end
  end

  describe "what the predicate refuses to read" do
    # sabotage: `compatible_at?/3`'s refusal arm answers true when
    # `import/2` onto `to_machine` refuses -> red
    test "the record's rename: awaiting_pickup renamed to ready_for_pickup is not compatible" do
      to =
        @hold
        |> String.replace("awaiting_pickup", "ready_for_pickup")
        |> edit(
          ~s(<final id="collected"/>),
          ~s(<state id="in_transfer">
                <transition event="copy.routed" target="ready_for_pickup"/>
            </state>
            <final id="collected"/>)
        )

      refute Position.compatible_at?(chart(@hold), chart(to), waiting_hold())
    end

    # sabotage: `compatible_at?/3`'s guard drops `is_binary(to_source)`
    # -> red (it raises in `Location.slice/2`)
    test "a machine with no source is not compatible" do
      machine = chart(@hold)
      exported = waiting_hold()

      refute Position.compatible_at?(machine, %{machine | source: nil}, exported)
      refute Position.compatible_at?(%{machine | source: nil}, machine, exported)
    end

    # sabotage: `compatible_at?/3`'s fallback clause is removed -> red
    # (FunctionClauseError)
    test "an argument the predicate cannot read answers false rather than raising" do
      machine = chart(@hold)

      refute Position.compatible_at?(machine, machine, :not_an_export)
      refute Position.compatible_at?(machine, machine, %{})
      refute Position.compatible_at?(:not_a_machine, machine, waiting_hold())

      refute Position.compatible_at?(
               machine,
               machine,
               %{waiting_hold() | configuration: :not_a_set}
             )
    end

    # sabotage: `compatible_at?/3` skips `import/2` onto `from_machine` ->
    # red (it raises resolving an id the pinned chart does not have)
    test "an export naming a state the pinned chart does not have is not compatible" do
      machine = chart(@hold)
      foreign = %{waiting_hold() | configuration: MapSet.new(["in_transfer"])}
      to = edit(@hold, ~s(<final id="collected"/>), ~s(<state id="in_transfer"/>
          <final id="collected"/>))

      refute Position.compatible_at?(machine, chart(to), foreign)
    end

    # sabotage: `compatible_at?/3` reads `exported.datamodel` or
    # `timer_counter` and answers false when either differs from a fresh
    # export -> red
    test "the datamodel and the timer counter are not read" do
      machine = chart(@hold)

      exported = %{
        waiting_hold()
        | datamodel: %{"copy_id" => "c-2", "patron" => "p-9"},
          timer_counter: 42
      }

      assert Position.compatible_at?(machine, machine, exported)
    end
  end

  describe "who calls it" do
    # sabotage: a call to `compatible_at?` is added anywhere in `lib/`
    # outside its own definition in `lib/statifier/position.ex` -> red
    test "nothing in lib/ calls it outside its own module" do
      lib = Path.expand("../../lib", __DIR__)

      callers =
        lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          not String.ends_with?(path, "lib/statifier/position.ex") and
            path |> File.read!() |> String.contains?("compatible_at?")
        end)

      assert callers == []

      own_uses =
        lib
        |> Path.join("statifier/position.ex")
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "compatible_at?("))
        |> Enum.map(&String.trim/1)

      assert Enum.all?(
               own_uses,
               &String.starts_with?(&1, ["def compatible_at?(", "@spec compatible_at?("])
             )
    end
  end
end
