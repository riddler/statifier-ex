defmodule Statifier.Session.LoopChartShapeTest do
  @moduledoc """
  Pins the sequential loop-shaped chart the authoring layer compiles an
  "iterate a subgraph of states over a list" block down to: a plain Appendix
  D composition, with no engine construct behind it.

  The shape, as ruled:

    * a compiler-declared `<data>` root per loop holds the cursor, and a
      second holds a per-loop snapshot of the source list, assigned once at
      the loop state's `<onentry>` (spec 4.6.3's shallow copy)
    * the `item_as`/`index_as` bindings are declared `<data>` roots too -
      early binding makes them global, and predicator refuses undeclared
      roots - re-assigned in the head state's `<onentry>` each pass from
      `snapshot[cursor]`
    * the body compiles once, as a compound state whose `<final>` raises
      `done.state.<body>`
    * a loop-back transition on the loop state consumes that event,
      increments the cursor, and re-targets the head
    * termination is `snapshot[cursor] === undefined`, the out-of-bounds read

  Nothing in the engine knows any of this is a loop, which is the point of
  the ruling and the reason the composition needs pinning rather than the
  parts do.
  """

  use ExUnit.Case, async: true

  alias Statifier.Effect.DatamodelChange
  alias Statifier.{Event, Interpreter, Position, Session}

  # `Statifier.compile/1` (identified) is what `Position.to_binary/1` and
  # `:resume` both require on either side (ADR-0060 decision 2).
  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp changes(effects) do
    for {:datamodel_change, %DatamodelChange{} = payload} <- effects, do: payload
  end

  # The value written to `location` by this batch of effects, or `:none`.
  defp written(effects, location) do
    case Enum.filter(changes(effects), &(&1.location_source == location)) do
      [] -> :none
      list -> List.last(list).new_value
    end
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

  # -- the chart ------------------------------------------------------------

  # A signup wizard walking three steps, one external `step.submitted` per
  # pass, spelled exactly as the ruling's compile shape would emit it. The
  # `blk0__` prefix stands in for the compiler-generated per-loop ids; `step`
  # and `step_index` stand in for author-chosen `item_as`/`index_as` names.
  #
  # Two details the ruling's prose leaves implicit and this chart makes
  # explicit, because the composition does not run without them:
  #
  #   * the loop-back transition is `type="internal"`. An external transition
  #     whose target is a descendant of its own source exits and re-enters
  #     that source (Appendix D `getTransitionDomain`/`findLCCA`), which would
  #     re-run `signup_steps`'s `<onentry>` - re-snapshotting the list and
  #     resetting the cursor to 0 on every pass, i.e. an infinite loop. The
  #     ruling's "re-enters the body's initial substate fresh" is only true of
  #     the internal form.
  #   * termination is spelled `===`, never `==`. Predicator's loose `==`
  #     against `undefined` returns `:undefined` rather than a boolean, and a
  #     `nil` list item does not satisfy `===` (verified against the resolved
  #     predicator 9.0.0 in this repo's deps) - so `===` is what distinguishes
  #     "ran off the end" from "the item at this index is empty".
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="signup_steps" datamodel="predicator">
      <datamodel>
          <data id="steps" expr="['email', 'profile', 'plan']"/>
          <data id="blk0__cursor" expr="0"/>
          <data id="blk0__items"/>
          <data id="step"/>
          <data id="step_index"/>
      </datamodel>
      <state id="signup_steps" initial="blk0__head">
          <onentry>
              <assign location="blk0__items" expr="steps"/>
              <assign location="blk0__cursor" expr="0"/>
          </onentry>
          <transition event="done.state.blk0__body" type="internal" target="blk0__head">
              <assign location="blk0__cursor" expr="blk0__cursor + 1"/>
          </transition>
          <state id="blk0__head">
              <onentry>
                  <assign location="step" expr="blk0__items[blk0__cursor]"/>
                  <assign location="step_index" expr="blk0__cursor"/>
              </onentry>
              <transition cond="blk0__items[blk0__cursor] === undefined" target="all_steps_done"/>
              <transition target="blk0__body"/>
          </state>
          <state id="blk0__body" initial="collecting">
              <state id="collecting">
                  <onentry>
                      <assign location="steps" expr="['mutated']"/>
                  </onentry>
                  <transition event="step.submitted" target="blk0__body_done"/>
              </state>
              <final id="blk0__body_done"/>
          </state>
      </state>
      <state id="all_steps_done"/>
  </scxml>
  """

  # The same shape over a list whose middle item is `null`. It exists to pin
  # the half of the termination test that is easy to get wrong: an empty item
  # is not the end of the list, and only `===` says so.
  @null_item_chart String.replace(
                     @chart,
                     ~s(expr="['email', 'profile', 'plan']"),
                     ~s(expr="['email', null, 'plan']")
                   )

  defp submit(machine_state) do
    {:ok, next, effects} =
      Interpreter.handle_event(machine_state, Event.external("step.submitted"))

    {next, effects}
  end

  defp leaves(machine_state), do: Statifier.active_leaf_states(machine_state)

  # -- iteration ------------------------------------------------------------

  describe "the ruled loop shape over a three-item list" do
    # sabotage: `Statifier.Interpreter.ExitEntry`'s `raise_parent_completion/3`
    # has its named-parent guard inverted (`parent_id != ""` -> `parent_id ==
    # ""`), so every final falls to the `_no_id` clause and no
    # `done.state.<parent>` is ever raised -> the loop-back transition never
    # fires, nothing writes `step` on the second submit, and
    # `written(effects2, "step")` comes back `:none` instead of "profile".
    # Reverted and confirmed green.
    test "binds item and index once per pass and enters the body each time" do
      machine = compile!(@chart)

      {pass1, init_effects} = Interpreter.initialize(machine)

      # Pass 1: the loop state's onentry snapshots, the head binds from
      # snapshot[0], and the unconditional eventless transition falls into
      # the body's initial substate - all inside the initial macrostep.
      assert written(init_effects, "blk0__items") == ["email", "profile", "plan"]
      assert written(init_effects, "step") == "email"
      assert written(init_effects, "step_index") == 0
      assert leaves(pass1) == MapSet.new(["collecting"])

      {pass2, effects2} = submit(pass1)

      assert written(effects2, "blk0__cursor") == 1
      assert written(effects2, "step") == "profile"
      assert written(effects2, "step_index") == 1
      assert leaves(pass2) == MapSet.new(["collecting"])

      {pass3, effects3} = submit(pass2)

      assert written(effects3, "blk0__cursor") == 2
      assert written(effects3, "step") == "plan"
      assert written(effects3, "step_index") == 2
      assert leaves(pass3) == MapSet.new(["collecting"])

      # The snapshot is never re-taken: the loop state is entered exactly
      # once, so exactly one write to it lands across the whole run.
      assert written(effects2, "blk0__items") == :none
      assert written(effects3, "blk0__items") == :none
    end

    # sabotage: `Statifier.Interpreter.Selection`'s `transition_domain/3` has
    # its internal-transition test inverted (`type == :internal` -> `type ==
    # :external`), so the loop-back transition's domain becomes the LCCA
    # instead of its own source -> "signup_steps" is exited and re-entered
    # every pass, its `<onentry>` re-snapshots from the list the body has
    # already mutated, and `written(effects2, "step")` comes back "mutated"
    # instead of "profile". Reverted and confirmed green.
    test "a body mutation of the source list does not change the iteration" do
      machine = compile!(@chart)

      {pass1, _init_effects} = Interpreter.initialize(machine)

      # The body already ran its mutation on entry to pass 1.
      assert pass1.datamodel["steps"] == ["mutated"]
      assert pass1.datamodel["blk0__items"] == ["email", "profile", "plan"]

      {pass2, effects2} = submit(pass1)
      {pass3, effects3} = submit(pass2)

      # Iteration follows the snapshot, so it still walks all three items
      # even though the source list has been one element long since pass 1.
      assert written(effects2, "step") == "profile"
      assert written(effects3, "step") == "plan"
      assert pass3.datamodel["steps"] == ["mutated"]
      assert pass3.datamodel["blk0__items"] == ["email", "profile", "plan"]
    end

    # sabotage: `Statifier.Interpreter.Selection`'s `evaluate_cond/2` has its
    # falsy arm changed to pass (`{:ok, false} -> {:ok, false}` becomes
    # `{:ok, false} -> {:ok, true}`), so the termination cond is no longer
    # consulted -> the head takes the exit arrow on the very first pass, the
    # loop ends before any submit, and `written(effects, "blk0__cursor")`
    # comes back `:none` instead of 3. Reverted and confirmed green.
    test "terminates on the out-of-bounds === undefined read, not on a count" do
      machine = compile!(@chart)

      {pass1, _effects} = Interpreter.initialize(machine)
      {pass2, _effects} = submit(pass1)
      {pass3, _effects} = submit(pass2)
      {finished, effects} = submit(pass3)

      # The fourth head entry binds the out-of-bounds read, then takes the
      # conditional arrow out of the loop.
      assert written(effects, "blk0__cursor") == 3
      assert written(effects, "step") == :undefined
      assert written(effects, "step_index") == 3
      assert leaves(finished) == MapSet.new(["all_steps_done"])

      # The loop is over: another submit is inert.
      {again, again_effects} = submit(finished)
      assert leaves(again) == MapSet.new(["all_steps_done"])
      assert changes(again_effects) == []
    end

    # sabotage: `Statifier.Machine.Content.Assign`'s `evaluate_value/2`
    # over-applies ADR-0037's "unbound is spelled undefined at the writer" to
    # a genuine null, mapping an evaluated `nil` to `:undefined` on the way
    # into the write -> the `null` item stops being distinguishable from the
    # out-of-bounds read, and `written(effects2, "step")` comes back
    # `:undefined` instead of `nil`. Reverted and confirmed green.
    test "a null item is iterated, not mistaken for the end of the list" do
      machine = compile!(@null_item_chart)

      {pass1, init_effects} = Interpreter.initialize(machine)
      assert written(init_effects, "step") == "email"
      assert leaves(pass1) == MapSet.new(["collecting"])

      # Index 1 holds `null`. `=== undefined` is false for it, so the loop
      # binds it and runs the body a second time rather than terminating -
      # the distinction the loose `==` form would lose (it answers
      # `:undefined`, not a boolean, against `undefined` at all).
      {pass2, effects2} = submit(pass1)
      assert written(effects2, "step") == nil
      assert written(effects2, "step_index") == 1
      assert leaves(pass2) == MapSet.new(["collecting"])

      {pass3, effects3} = submit(pass2)
      assert written(effects3, "step") == "plan"
      assert leaves(pass3) == MapSet.new(["collecting"])

      # Only the out-of-bounds read ends it.
      {finished, effects} = submit(pass3)
      assert written(effects, "step") == :undefined
      assert leaves(finished) == MapSet.new(["all_steps_done"])
    end
  end

  # -- resume ---------------------------------------------------------------

  describe "a persist/resume between pass 2 and pass 3" do
    # sabotage: `Statifier.Session`'s resumed `boot/6` clause returns
    # `elem(Interpreter.initialize(machine, machine_opts), 0)` instead of the
    # stamped decoded position, so the session re-initializes rather than
    # continuing -> "signup_steps"'s `<onentry>` runs again and resets the
    # cursor, and `snapshot.datamodel["blk0__cursor"]` comes back 0 instead
    # of 2. Reverted and confirmed green.
    test "resumes with the cursor and the bound item intact and finishes the loop" do
      machine = compile!(@chart)

      {pass1, _effects} = Interpreter.initialize(machine)
      {pass2, _effects} = submit(pass1)
      {parked, _effects} = submit(pass2)

      # Parked mid-loop: waiting in pass 3's body, item and index bound.
      assert leaves(parked) == MapSet.new(["collecting"])
      assert parked.datamodel["blk0__cursor"] == 2
      assert parked.datamodel["step"] == "plan"
      assert parked.datamodel["step_index"] == 2

      assert {:ok, blob} = Position.to_binary(parked)

      {:ok, session} = Session.start_link(machine, resume: blob, subscribers: [self()])
      session_id = Session.session_id(session)

      snapshot = Session.snapshot(session)
      assert Statifier.active_leaf_states(snapshot) == MapSet.new(["collecting"])
      assert snapshot.datamodel["blk0__cursor"] == 2
      assert snapshot.datamodel["step"] == "plan"
      assert snapshot.datamodel["blk0__items"] == ["email", "profile", "plan"]

      # The resumed session runs the last pass and leaves the loop on the
      # same out-of-bounds test the pure core took.
      Session.send_event(session, "step.submitted")

      status =
        wait_for_status(session, fn s -> s.configuration == MapSet.new(["all_steps_done"]) end)

      assert status.configuration == MapSet.new(["all_steps_done"])

      assert_receive {:statifier, ^session_id,
                      {:effect, {:datamodel_change, %DatamodelChange{location_source: "step"}}}}

      final = Session.snapshot(session)
      assert final.datamodel["blk0__cursor"] == 3
      assert final.datamodel["step"] == :undefined
      assert final.datamodel["step_index"] == 3
    end
  end
end
