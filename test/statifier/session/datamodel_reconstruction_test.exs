defmodule Statifier.Session.DatamodelReconstructionTest do
  use ExUnit.Case, async: true

  # The bead's own acceptance criterion: the datamodel can be
  # reconstructed from the `{:datamodel_change, _}` effect stream alone,
  # without ever calling `Session.snapshot/1`. Three `<assign>` forms - a
  # scalar overwrite, a deep path vivification, and a bracket index - are
  # driven through one real `Statifier.Session`, all inside the initial
  # macrostep (no external event is needed to exercise the point).

  alias Statifier.Compiler
  alias Statifier.Effect.DatamodelChange
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

  # Decision 6's stated gap: the initial datamodel binding (this chart's own
  # <data> elements) is not on the effect stream - only writes are. A
  # consumer folding the effect stream alone still needs the starting map
  # from some other channel. Putting the initial binding on the stream too -
  # <data> binding, the environment seed, and the system variables - is
  # separate work, tracked outside the code. This literal is that other
  # channel, restated here rather than
  # read off `Session.snapshot/1`, so the reconstruction below never touches
  # the oracle it is meant to be checked against.
  @starting_datamodel %{"x" => 1, "a" => nil, "items" => [10, 20, 30]}

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

  defp collect_datamodel_changes(session_id, acc \\ []) do
    receive do
      {:statifier, ^session_id, {:effect, {:datamodel_change, %DatamodelChange{} = change}}} ->
        collect_datamodel_changes(session_id, [change | acc])
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

    changes = collect_datamodel_changes(session_id)
    # 3 <data> bindings (ahead of the 3 <assign>s below in the stream) + the
    # 3 <assign>s themselves. The bindings' own new_values
    # equal @starting_datamodel's literal exactly, so folding them is a
    # no-op on the reconstruction below - this count moves again, and the
    # literal above is retired, in the phase that puts the baseline on the
    # stream instead.
    assert length(changes) == 6

    reconstructed = reconstruct(@starting_datamodel, changes)

    assert reconstructed == %{
             "x" => 2,
             "a" => %{"b" => %{"c" => 99}},
             "items" => [10, 42, 30]
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

    changes = collect_datamodel_changes(session_id)
    reconstructed = reconstruct(@starting_datamodel, changes)

    snapshot_datamodel = Session.snapshot(session).datamodel
    oracle = Map.take(snapshot_datamodel, Map.keys(@starting_datamodel))

    assert reconstructed == oracle
  end
end
