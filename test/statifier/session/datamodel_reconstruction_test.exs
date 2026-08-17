defmodule Statifier.Session.DatamodelReconstructionTest do
  use ExUnit.Case, async: true

  # The bead's own acceptance criterion: the whole datamodel - starting map
  # and every change after it - can be reconstructed from the core effect
  # stream alone, without ever calling `Session.snapshot/1` or holding a
  # `%Machine{}` handle. The fold seeds from the one `{:datamodel_init, _}`
  # baseline and applies every `{:datamodel_change, _}` after it at
  # `location_path`. Three `<assign>` forms - a scalar overwrite, a deep
  # path vivification, and a bracket index - are driven through one real
  # `Statifier.Session`, all inside the initial macrostep (no external event
  # is needed to exercise the point).

  alias Statifier.Compiler
  alias Statifier.Effect.DatamodelChange
  alias Statifier.Effect.DatamodelInit
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="x" expr="1"/>
          <data id="a"/>
          <data id="items" expr="[10, 20, 30]"/>
      </datamodel>
      <state id="s0">
          <onentry>
              <assign location="x" expr="2"/>
              <assign location="a.b.c" expr="99"/>
              <assign location="items[1]" expr="42"/>
          </onentry>
      </state>
  </scxml>
  """

  @late_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
      <state id="s0">
          <transition event="go" target="s1"/>
      </state>
      <state id="s1">
          <datamodel>
              <data id="Var1" expr="1"/>
          </datamodel>
      </state>
  </scxml>
  """

  @shadow_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="x" expr="1"/>
      </datamodel>
      <state id="s0"/>
  </scxml>
  """

  # A small local put_in-style walk over `location_path` -
  # `Predicator.ContextLocation` has `put/3` but this test deliberately does
  # not reach for it: the point is that a consumer with no predicator
  # dependency at all can still apply the effect stream.
  defp apply_path(container, [key], value) when is_binary(key), do: Map.put(container, key, value)

  defp apply_path(container, [index], value) when is_integer(index),
    do: List.replace_at(container, index, value)

  defp apply_path(container, [key | rest], value) when is_binary(key) do
    Map.put(container, key, apply_path(Map.get(container, key) || %{}, rest, value))
  end

  defp apply_path(container, [index | rest], value) when is_integer(index) do
    List.replace_at(container, index, apply_path(Enum.at(container, index) || [], rest, value))
  end

  defp reconstruct(datamodel, []), do: datamodel

  defp reconstruct(datamodel, [%DatamodelChange{location_path: path, new_value: value} | rest]) do
    reconstruct(apply_path(datamodel, path, value), rest)
  end

  # Collects both tags a reconstruction needs: the one `:datamodel_init`
  # baseline and every `:datamodel_change` after it, in arrival order.
  defp collect_datamodel_effects(session_id, acc \\ []) do
    receive do
      {:statifier, ^session_id, {:effect, {:datamodel_init, %DatamodelInit{}} = effect}} ->
        collect_datamodel_effects(session_id, [effect | acc])

      {:statifier, ^session_id, {:effect, {:datamodel_change, %DatamodelChange{}} = effect}} ->
        collect_datamodel_effects(session_id, [effect | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # sabotage: `Assign`'s `execute/2` builds the `{:datamodel_change, _}`
  # effect with `location_path: [node.location]` (the raw string wrapped in
  # a list) instead of `write.path` (the resolved path), and `prior_value:
  # nil` instead of `write.prior_value` - the two fields decision 4/7 make
  # the whole reconstruction depend on -> the fold below still runs (every
  # path is one segment against the wrong key), but the reconstructed map's
  # `"x"` key comes back wrong and the `a.b.c` write no longer nests,
  # reddening both the reconstruction and oracle assertions. Confirmed red
  # and reverted.
  test "the effect stream alone reconstructs the datamodel, without Session.snapshot/1" do
    machine = compile!(@document)
    {:ok, session} = Session.start_link(machine, subscribers: [self()])
    session_id = Session.session_id(session)

    effects = collect_datamodel_effects(session_id)

    # Exactly one baseline, and it precedes every change: destructuring the
    # head as the sole `:datamodel_init` match, then asserting every
    # remaining effect is a `:datamodel_change`, rules out a second baseline
    # hiding later in the stream.
    assert [{:datamodel_init, %DatamodelInit{datamodel: baseline}} | changes] = effects
    assert Enum.all?(changes, &match?({:datamodel_change, _}, &1))

    # 3 <data> bindings (ahead of the 3 <assign>s below in the stream) + the
    # 3 <assign>s themselves.
    assert length(changes) == 6

    change_structs = Enum.map(changes, fn {:datamodel_change, change} -> change end)
    reconstructed = reconstruct(baseline, change_structs)

    assert reconstructed == %{
             "x" => 2,
             "a" => %{"b" => %{"c" => 99}},
             "items" => [10, 42, 30],
             "_sessionid" => session_id,
             "_name" => :undefined,
             "_event" => :undefined,
             "_ioprocessors" => %{
               SystemVariables.scxml_event_processor() => %{
                 "location" => SystemVariables.scxml_location(session_id)
               }
             }
           }
  end

  # Separately labeled oracle: the reconstruction above stands without this -
  # it never calls `Session.snapshot/1` - but this proves the two channels
  # agree, rather than merely proving the fold arithmetic works.
  # sabotage: same mutation as above (`location_path: [node.location]`,
  # `prior_value: nil`) also reddens this assertion against the
  # `Session.snapshot/1` oracle, since the reconstructed map and the oracle
  # then disagree on every key. Confirmed red and reverted.
  test "the reconstruction agrees with Session.snapshot/1's datamodel (oracle)" do
    machine = compile!(@document)
    {:ok, session} = Session.start_link(machine, subscribers: [self()])
    session_id = Session.session_id(session)

    effects = collect_datamodel_effects(session_id)
    assert [{:datamodel_init, %DatamodelInit{datamodel: baseline}} | changes] = effects
    change_structs = Enum.map(changes, fn {:datamodel_change, change} -> change end)
    reconstructed = reconstruct(baseline, change_structs)

    snapshot_datamodel = Session.snapshot(session).datamodel

    # Decision 8: `"_event"` is the one datamodel key no `write_location/4`
    # write and no binding ever produces - `MachineState.put_event/2` is its
    # sole writer, outside any effect list, so the baseline's own seeded
    # `:undefined` for it never changes on the stream while the live
    # datamodel's does as events are processed. Both sides drop it before
    # comparing, so the assertion is "every other key agrees", not "every
    # key including one this plan explicitly does not reconstruct".
    oracle = Map.delete(snapshot_datamodel, "_event")

    assert Map.delete(reconstructed, "_event") == oracle
  end

  # sabotage: `Datamodel.bind_state_data/4`'s `:late` clause is changed to
  # `Enum.reduce([], ms, ...)` (dropping the state's own `d_indexes`) ->
  # `enter_state/2` emits no `{:datamodel_change, _}` for `Var1` when `s1`
  # is entered, so the post-event reconstruction stays `:undefined` instead
  # of `1`, reddening the last assertion below. Confirmed red and reverted.
  test "late binding: the post-event reconstruction reflects the binding effect a single init-time snapshot could not have captured" do
    machine = compile!(@late_document)
    {:ok, session} = Session.start_link(machine, subscribers: [self()])
    session_id = Session.session_id(session)

    init_effects = collect_datamodel_effects(session_id)

    # `s0` declares no `<datamodel>` of its own, so the only effect from
    # initialization is the baseline - `s1`'s `Var1` is not bound yet.
    assert [{:datamodel_init, %DatamodelInit{datamodel: baseline}}] = init_effects
    assert baseline["Var1"] == :undefined
    assert reconstruct(baseline, []) == baseline

    Session.send_event(session, "go")
    change_effects = collect_datamodel_effects(session_id)
    changes = Enum.map(change_effects, fn {:datamodel_change, change} -> change end)

    assert Enum.any?(changes, &(&1.location_path == ["Var1"] and &1.new_value == 1))

    reconstructed_after_event = reconstruct(baseline, changes)
    assert reconstructed_after_event["Var1"] == 1
  end

  # sabotage: `Datamodel.bind/6`'s environment-skip guard is deleted, so a
  # top-level `<data>` id the environment supplied gets rebound from the
  # document's own `expr` anyway -> a `{:datamodel_change, _}` for `"x"`
  # arrives (reddening the `refute` below) and the reconstruction's `"x"`
  # flips from `"from-env"` back to `1` (reddening the final assertion).
  # Confirmed red and reverted.
  test "environment :datamodel: the baseline alone reproduces both the shadowed and unshadowed keys" do
    machine = compile!(@shadow_document)

    {:ok, session} =
      Session.start_link(machine,
        subscribers: [self()],
        datamodel: %{"x" => "from-env", "extra" => "env-only"}
      )

    session_id = Session.session_id(session)

    effects = collect_datamodel_effects(session_id)
    assert [{:datamodel_init, %DatamodelInit{datamodel: baseline}} | changes] = effects

    assert baseline["x"] == "from-env"
    assert baseline["extra"] == "env-only"

    # Decision 5: an environment-shadowed top-level <data> binding is
    # skipped entirely, so it contributes no :datamodel_change.
    refute Enum.any?(changes, fn {:datamodel_change, change} -> change.location_path == ["x"] end)

    change_structs = Enum.map(changes, fn {:datamodel_change, change} -> change end)
    reconstructed = reconstruct(baseline, change_structs)

    assert reconstructed["x"] == "from-env"
    assert reconstructed["extra"] == "env-only"
  end

  # sabotage: `Datamodel.initialize/1`'s `init_effect` is wrapped in
  # `if machine_state.trace, do: [init_effect], else: []` - treating the
  # core baseline as if it were trace-gated - so under `trace: false` no
  # `:datamodel_init` effect ever arrives, reddening the destructuring
  # match below. Confirmed red and reverted.
  test "trace: false leaves the reconstruction unchanged - both effects are core" do
    machine = compile!(@late_document)
    {:ok, session} = Session.start_link(machine, subscribers: [self()], trace: false)
    session_id = Session.session_id(session)

    init_effects = collect_datamodel_effects(session_id)
    assert [{:datamodel_init, %DatamodelInit{datamodel: baseline}}] = init_effects

    Session.send_event(session, "go")
    change_effects = collect_datamodel_effects(session_id)
    changes = Enum.map(change_effects, fn {:datamodel_change, change} -> change end)

    reconstructed = reconstruct(baseline, changes)
    assert reconstructed["Var1"] == 1
  end
end
