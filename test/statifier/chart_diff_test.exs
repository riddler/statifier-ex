defmodule Statifier.ChartDiffTest do
  @moduledoc """
  `Statifier.Chart.diff/3`: two compiled charts classified as identical,
  compatible, mapped or breaking, with their reasons (ADR-0072 decisions 1
  and 2). Every chart is in the library world (patron, copy, loan, hold,
  branch). The hold chart below is the record's worked example; the hold
  queue chart is read from `conformance/cases/library/`, never edited, and
  its edited revisions are made from it in memory. Each other pair isolates
  one reason, so that reason is the only thing the answer can hold.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Chart, Compiler, Lowering, Parser}

  @hold_queue Path.expand(
                "../../conformance/cases/library/hold_queue_available_with_no_holds.scxml",
                __DIR__
              )

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

  # The edited revision: `awaiting_pickup` renamed to `ready_for_pickup`
  # (its body unchanged), `routing` gains a `copy.transferred` outcome, and
  # a state `in_transfer` routes the copy back.
  @hold_renamed """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="routing">
          <datamodel>
              <data id="copy_id" expr="'c-1'"/>
          </datamodel>
          <state id="routing">
              <transition event="copy.routed" target="ready_for_pickup"/>
              <transition event="copy.transferred" target="in_transfer"/>
          </state>
          <state id="ready_for_pickup">
              <onentry>
                  <send type="library:timer" target="hold" event="pickup.expired" id="pickup" delay="7d"/>
              </onentry>
              <onexit>
                  <cancel sendid="pickup"/>
              </onexit>
              <transition event="copy.collected" target="collected"/>
              <transition event="pickup.expired" target="expired"/>
          </state>
          <state id="in_transfer">
              <transition event="copy.routed" target="ready_for_pickup"/>
          </state>
          <final id="collected"/>
          <final id="expired"/>
      </scxml>
  """

  defp chart(xml, opts \\ []) do
    {:ok, machine} = Statifier.compile(xml, opts)
    machine
  end

  # A machine with no identity and no source: straight from the compiler.
  defp bare(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp hold_queue, do: File.read!(@hold_queue)

  # Rewrites `xml`, failing loudly when `pattern` is not in it, so an edit
  # that silently did nothing cannot pass for "no difference".
  defp edit(xml, pattern, replacement) do
    assert String.contains?(xml, pattern), "edit pattern not found: #{pattern}"
    String.replace(xml, pattern, replacement, global: false)
  end

  describe "the four classes" do
    # sabotage: `diff/3` skips its `Identity.matches?/2` check and always
    # runs the structural comparison -> red (class :compatible)
    test "the same chart compiled twice is identical, with no reasons" do
      assert Chart.diff(chart(@hold), chart(@hold)) == %{class: :identical, reasons: []}
    end

    # sabotage: `classify/1` answers :identical when `reasons` is `[]` -> red
    test "the same bytes under another chart name are compatible, with no reasons" do
      assert Chart.diff(chart(@hold, chart_name: "hold"), chart(@hold, chart_name: "hold_v2")) ==
               %{class: :compatible, reasons: []}
    end

    # sabotage: `diff/3` compares the identities with `==/2` (nil == nil)
    # -> red (class :identical)
    test "a machine with no identity is never identical, even to its own bytes" do
      assert Chart.diff(bare(@hold), bare(@hold)) == %{class: :compatible, reasons: []}
    end

    # sabotage: `breaking?/1` answers true for `:transition_added` -> red
    test "a new optional state and outcome are compatible, each addition reported" do
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

      assert Chart.diff(chart(@hold), chart(to)) == %{
               class: :compatible,
               reasons: [
                 {:state_added, "in_transfer"},
                 {:transition_added, "routing", 1},
                 {:event_added, "copy.transferred"}
               ]
             }
    end

    # sabotage: `correspondence/3` pairs only mapped ids (the shared-id
    # branch dropped) -> red
    test "the renamed wait state without a mapping is breaking, as the record works it" do
      assert Chart.diff(chart(@hold), chart(@hold_renamed)) == %{
               class: :breaking,
               reasons: [
                 {:state_unresolved, "awaiting_pickup"},
                 {:state_added, "ready_for_pickup"},
                 {:state_added, "in_transfer"},
                 {:transition_removed, "routing", 0},
                 {:transition_added, "routing", 0},
                 {:transition_added, "routing", 1},
                 {:event_added, "copy.transferred"}
               ]
             }
    end

    # sabotage: `correspondence/3` drops the read mapping entries
    # (`Map.get(read, id)` becomes `nil`) -> red
    test "the renamed wait state with a mapping is mapped, as the record works it" do
      assert Chart.diff(chart(@hold), chart(@hold_renamed),
               mapping: %{"awaiting_pickup" => "ready_for_pickup"}
             ) == %{
               class: :mapped,
               reasons: [
                 {:state_mapped, "awaiting_pickup", "ready_for_pickup"},
                 {:state_added, "in_transfer"},
                 {:transition_added, "routing", 1},
                 {:event_added, "copy.transferred"}
               ]
             }
    end
  end

  describe "transitions" do
    # sabotage: `transition_reasons/4` reports removals only for states that
    # are NOT held -> red
    test "a removed transition from a state that can be active is breaking" do
      xml = hold_queue()

      to =
        edit(
          xml,
          ~s(<transition event="copy.available" target="idle"/>),
          ""
        )

      assert Chart.diff(chart(xml), chart(to)) == %{
               class: :breaking,
               reasons: [{:transition_removed, "idle", 2}]
             }
    end

    # sabotage: `transition_reasons/4` reports removals for every
    # corresponding state, held or not -> red (the archived state's old
    # transition comes back as removed)
    test "a state no path enters reports its new transition and never its old one" do
      from =
        edit(
          @hold,
          ~s(<final id="collected"/>),
          ~s(<state id="archived">
            <transition event="loan.renew" target="routing"/>
        </state>
        <final id="collected"/>)
        )

      to = edit(from, ~s(event="loan.renew"), ~s(event="copy.available"))

      assert Chart.diff(chart(from), chart(to)) == %{
               class: :compatible,
               reasons: [{:transition_added, "archived", 3}]
             }
    end

    # sabotage: `match_transitions/5` matches a transition only against the
    # first remaining one (by position, not as a multiset) -> red
    test "a reordering of a state's transitions is not reported" do
      to =
        edit(
          @hold,
          ~s(<transition event="copy.collected" target="collected"/>
            <transition event="pickup.expired" target="expired"/>),
          ~s(<transition event="pickup.expired" target="expired"/>
            <transition event="copy.collected" target="collected"/>)
        )

      assert Chart.diff(chart(@hold), chart(to)) == %{class: :compatible, reasons: []}
    end

    # sabotage: `cond_key/1` drops the expression's source (every compiled
    # cond compares equal) -> red
    test "a condition compares by its source text" do
      xml = hold_queue()
      to = edit(xml, ~s(cond="pending &gt; 0"), ~s(cond="pending &gt; 2"))

      assert Chart.diff(chart(xml), chart(to)) == %{
               class: :breaking,
               reasons: [{:transition_removed, "idle", 1}, {:transition_added, "idle", 1}]
             }
    end

    # sabotage: `list_delta/4` drops the `from -- to` half -> red
    test "a removed event is breaking" do
      to = edit(@hold, ~s(event="copy.collected"), ~s(event="copy.picked_up"))

      assert Chart.diff(chart(@hold), chart(to)) == %{
               class: :breaking,
               reasons: [
                 {:transition_removed, "awaiting_pickup", 1},
                 {:transition_added, "awaiting_pickup", 1},
                 {:event_removed, "copy.collected"},
                 {:event_added, "copy.picked_up"}
               ]
             }
    end
  end

  describe "states" do
    # sabotage: `from_state_reason/6`'s held nameless clause returns `[]`
    # -> red
    test "a nameless state that can be active is breaking; one that cannot is ignored" do
      xml = """
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="waiting">
              <state id="waiting">
                  <state>
                      <transition event="copy.collected" target="collected"/>
                  </state>
                  <state/>
              </state>
              <final id="collected"/>
          </scxml>
      """

      assert Chart.diff(chart(xml, chart_name: "a"), chart(xml, chart_name: "b")) == %{
               class: :breaking,
               reasons: [{:state_nameless, 2}]
             }
    end

    # sabotage: `from_state_reason/6`'s not-held, no-correspondent clause
    # answers `:state_unresolved` -> red
    test "a removed state no path enters is reported and not breaking" do
      from =
        edit(@hold, ~s(<final id="collected"/>), ~s(<state id="archived"/>
        <final id="collected"/>))

      assert Chart.diff(chart(from), chart(@hold)) == %{
               class: :compatible,
               reasons: [{:state_removed, "archived"}]
             }
    end

    # sabotage: `held_states/1` treats a history as held only when entered
    # itself -> red (the history comes back as `:state_removed`)
    test "a removed history whose parent can be active is unresolved" do
      from = """
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="loan">
              <state id="loan">
                  <state id="on_loan">
                      <transition event="loan.renew" target="on_loan"/>
                  </state>
                  <history id="loan_history">
                      <transition target="on_loan"/>
                  </history>
              </state>
          </scxml>
      """

      to =
        edit(
          from,
          ~s(<history id="loan_history">
                <transition target="on_loan"/>
            </history>),
          ""
        )

      assert Chart.diff(chart(from), chart(to)) == %{
               class: :breaking,
               reasons: [{:state_unresolved, "loan_history"}]
             }
    end

    # sabotage: `changed_fields/3` never reports `:kind` -> red
    test "a held state whose kind changed is breaking" do
      to = edit(@hold, ~s(<final id="collected"/>), ~s(<state id="collected"/>))

      assert Chart.diff(chart(@hold), chart(to)) == %{
               class: :breaking,
               reasons: [{:state_changed, "collected", [:kind]}]
             }
    end

    # sabotage: `changed_fields/3` never reports `:parent` -> red
    test "a held state moved under another parent is breaking" do
      to =
        edit(
          @hold,
          ~s(<final id="collected"/>),
          ~s(<state id="closed">
            <final id="collected"/>
        </state>)
        )

      assert Chart.diff(chart(@hold), chart(to)) == %{
               class: :breaking,
               reasons: [{:state_changed, "collected", [:parent]}, {:state_added, "closed"}]
             }
    end

    # sabotage: `changed_fields/3` never reports `:atomic` -> red
    test "a held atomic state that gained a child is breaking" do
      to =
        edit(
          @hold,
          ~s(<transition event="copy.collected" target="collected"/>),
          ~s(<state id="on_shelf"/>
            <transition event="copy.collected" target="collected"/>)
        )

      assert Chart.diff(chart(@hold), chart(to)) == %{
               class: :breaking,
               reasons: [
                 {:state_changed, "awaiting_pickup", [:atomic]},
                 {:state_added, "on_shelf"}
               ]
             }
    end

    # sabotage: `changed_fields/3` never reports `:regions` -> red
    test "a parallel state that gained a region is breaking" do
      from = """
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="patron">
              <parallel id="patron">
                  <state id="standing">
                      <transition event="patron.blocked" target="standing"/>
                  </state>
                  <state id="fines">
                      <transition event="fine.assessed" target="fines"/>
                  </state>
              </parallel>
          </scxml>
      """

      to =
        edit(from, ~s(</parallel>), ~s(    <state id="notices"/>
            </parallel>))

      assert Chart.diff(chart(from), chart(to)) == %{
               class: :breaking,
               reasons: [{:state_changed, "patron", [:regions]}, {:state_added, "notices"}]
             }
    end

    # sabotage: `changed_fields/3` never reports `:history_type` -> red
    test "a held history whose type changed is breaking" do
      from = """
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="loan">
              <state id="loan">
                  <state id="on_loan">
                      <transition event="loan.renew" target="on_loan"/>
                  </state>
                  <history id="loan_history" type="shallow">
                      <transition target="on_loan"/>
                  </history>
              </state>
          </scxml>
      """

      to = edit(from, ~s(type="shallow"), ~s(type="deep"))

      assert Chart.diff(chart(from), chart(to)) == %{
               class: :breaking,
               reasons: [{:state_changed, "loan_history", [:history_type]}]
             }
    end

    # sabotage: `from_state_reason/6` answers `:state_mapped` before it
    # checks the changed fields -> red
    test "a mapping onto a state of another kind is changed, not mapped" do
      to =
        @hold_renamed
        |> edit(
          ~s(<state id="in_transfer">
            <transition event="copy.routed" target="ready_for_pickup"/>
        </state>),
          ""
        )
        |> edit(~s(<transition event="copy.transferred" target="in_transfer"/>), "")
        |> edit(~s(<final id="collected"/>), ~s(<final id="shelved"/>
        <final id="collected"/>))

      assert Chart.diff(chart(@hold), chart(to), mapping: %{"awaiting_pickup" => "shelved"}) ==
               %{
                 class: :breaking,
                 reasons: [
                   {:state_changed, "awaiting_pickup", [:kind]},
                   {:state_added, "ready_for_pickup"},
                   {:transition_removed, "routing", 0},
                   {:transition_removed, "awaiting_pickup", 1},
                   {:transition_removed, "awaiting_pickup", 2},
                   {:transition_added, "routing", 0}
                 ]
               }
    end
  end

  describe "the datamodel" do
    # sabotage: `data_ids/1` reads only the root's own `data` d_indexes
    # rather than every `<data>` element -> red (the moved key is reported)
    test "a key declared anywhere counts; a removed key breaks and an added one reports" do
      from =
        edit(
          @hold,
          ~s(<cancel sendid="pickup"/>
            </onexit>),
          ~s(<cancel sendid="pickup"/>
            </onexit>
            <datamodel>
                <data id="pickup_branch" expr="'main'"/>
            </datamodel>)
        )

      to =
        @hold
        |> edit(~s(<data id="copy_id" expr="'c-1'"/>), ~s(<data id="patron_id" expr="'p-1'"/>
            <data id="pickup_branch" expr="'east'"/>))

      assert Chart.diff(chart(from), chart(to)) == %{
               class: :breaking,
               reasons: [{:data_removed, "copy_id"}, {:data_added, "patron_id"}]
             }
    end
  end

  describe "the mapping" do
    # sabotage: `read_mapping/3` reads an entry whose key is still present
    # in `to` -> red (the identity entry is read, and refused)
    test "entries the comparison does not read are reported unused, sorted by id" do
      assert Chart.diff(chart(@hold), chart(@hold_renamed),
               mapping: %{
                 "routing" => "routing",
                 "awaiting_pickup" => "branch_shelf",
                 "archived" => "ready_for_pickup"
               }
             ) == %{
               class: :breaking,
               reasons: [
                 {:state_unresolved, "awaiting_pickup"},
                 {:state_added, "ready_for_pickup"},
                 {:state_added, "in_transfer"},
                 {:transition_removed, "routing", 0},
                 {:transition_added, "routing", 0},
                 {:transition_added, "routing", 1},
                 {:event_added, "copy.transferred"},
                 {:mapping_unused, "archived"},
                 {:mapping_unused, "awaiting_pickup"},
                 {:mapping_unused, "routing"}
               ]
             }
    end

    # sabotage: `diff/3` checks `opts` only off the identical path
    # (`diff_mapping!/1` moved after `Identity.matches?/2`) -> red
    test "an unknown option or a mapping that is not strings to strings raises" do
      from = chart(@hold)

      assert_raise ArgumentError, ~r/accepts only :mapping/, fn ->
        Chart.diff(from, from, branch: "east")
      end

      assert_raise ArgumentError, ~r/must be a map from state ids/, fn ->
        Chart.diff(from, from, mapping: %{awaiting_pickup: "ready_for_pickup"})
      end

      assert_raise ArgumentError, ~r/must be a map from state ids/, fn ->
        Chart.diff(from, from, mapping: [{"awaiting_pickup", "ready_for_pickup"}])
      end

      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Chart.diff(from, from, %{mapping: %{}})
      end
    end

    # sabotage: `read_mapping/3`'s duplicate-value check is dropped -> red
    test "two read entries onto one state raise" do
      from = edit(@hold, ~s(<final id="expired"/>), ~s(<final id="expired"/>
        <final id="withdrawn"/>))

      assert_raise ArgumentError, ~r/maps two states onto "ready_for_pickup"/, fn ->
        Chart.diff(chart(from), chart(@hold_renamed),
          mapping: %{"awaiting_pickup" => "ready_for_pickup", "withdrawn" => "ready_for_pickup"}
        )
      end
    end

    # sabotage: `read_mapping/3`'s shared-value check is dropped -> red
    test "a read entry onto an id the old chart also declares raises" do
      assert_raise ArgumentError, ~r/maps a state onto "routing"/, fn ->
        Chart.diff(chart(@hold), chart(@hold_renamed), mapping: %{"awaiting_pickup" => "routing"})
      end
    end
  end
end
