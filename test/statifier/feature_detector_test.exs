defmodule Statifier.FeatureDetectorTest do
  use ExUnit.Case, async: true

  doctest Statifier.FeatureDetector

  alias Statifier.FeatureDetector

  # One document per registry entry. The completeness test below asserts this
  # table and the registry stay in step, so a new feature cannot land undetected.
  @samples %{
    basic_states: """
    <scxml><state id="s1"/></scxml>
    """,
    compound_states: """
    <scxml><state id="s1" initial="s2"><state id="s2"/></state></scxml>
    """,
    parallel_states: """
    <scxml><parallel id="p"><state id="a"/></parallel></scxml>
    """,
    final_states: """
    <scxml><final id="f"/></scxml>
    """,
    initial_elements: """
    <scxml><state id="s"><initial><transition target="a"/></initial></state></scxml>
    """,
    history_states: """
    <scxml><state id="s"><history id="h"><transition target="a"/></history></state></scxml>
    """,
    event_transitions: """
    <scxml><state id="s"><transition event="go" target="t"/></state></scxml>
    """,
    eventless_transitions: """
    <scxml><state id="s"><transition target="t"/></state></scxml>
    """,
    conditional_transitions: """
    <scxml><state id="s"><transition cond="ready" target="t"/></state></scxml>
    """,
    targetless_transitions: """
    <scxml><state id="s"><transition event="go"/></state></scxml>
    """,
    internal_transitions: """
    <scxml><state id="s"><transition type="internal" event="go"/></state></scxml>
    """,
    wildcard_events: """
    <scxml><state id="s"><transition event="*" target="t"/></state></scxml>
    """,
    event_expressions: """
    <scxml><state id="s"><onentry><send eventexpr="name"/></onentry></state></scxml>
    """,
    target_expressions: """
    <scxml><state id="s"><onentry><send targetexpr="dest"/></onentry></state></scxml>
    """,
    datamodel: """
    <scxml><datamodel><data id="x" expr="1"/></datamodel></scxml>
    """,
    data_elements: """
    <scxml><datamodel><data id="x" expr="1"/></datamodel></scxml>
    """,
    assign_elements: """
    <scxml><state id="s"><onentry><assign location="x" expr="1"/></onentry></state></scxml>
    """,
    script_elements: """
    <scxml><script>var x = 1;</script></scxml>
    """,
    onentry_actions: """
    <scxml><state id="s"><onentry><log expr="1"/></onentry></state></scxml>
    """,
    onexit_actions: """
    <scxml><state id="s"><onexit><log expr="1"/></onexit></state></scxml>
    """,
    if_elements: """
    <scxml><state id="s"><onentry><if cond="ready"><log expr="1"/></if></onentry></state></scxml>
    """,
    foreach_elements: """
    <scxml><state id="s"><onentry><foreach array="xs" item="x"/></onentry></state></scxml>
    """,
    log_elements: """
    <scxml><state id="s"><onentry><log expr="1"/></onentry></state></scxml>
    """,
    raise_elements: """
    <scxml><state id="s"><onentry><raise event="go"/></onentry></state></scxml>
    """,
    send_elements: """
    <scxml><state id="s"><onentry><send event="go"/></onentry></state></scxml>
    """,
    send_content_elements: """
    <scxml><state id="s"><onentry><send><content expr="1"/></send></onentry></state></scxml>
    """,
    send_param_elements: """
    <scxml><state id="s"><onentry><send><param name="p" expr="1"/></send></onentry></state></scxml>
    """,
    send_delay_expressions: """
    <scxml><state id="s"><onentry><send event="go" delay="1s"/></onentry></state></scxml>
    """,
    send_idlocation: """
    <scxml><state id="s"><onentry><send event="go" idlocation="x"/></onentry></state></scxml>
    """,
    cancel_elements: """
    <scxml><state id="s"><onentry><cancel sendid="s1"/></onentry></state></scxml>
    """,
    invoke_elements: """
    <scxml><state id="s"><invoke type="scxml" src="child.scxml"/></state></scxml>
    """,
    finalize_elements: """
    <scxml><state id="s"><invoke src="c.scxml"><finalize><log expr="1"/></finalize></invoke></state></scxml>
    """,
    donedata_elements: """
    <scxml><final id="f"><donedata><content expr="1"/></donedata></final></scxml>
    """
  }

  describe "detect_features/1" do
    # sabotage: n/a - FeatureDetector lives in test/support/, not lib/; each
    #           generated test asserts one @samples entry against it
    for {feature, xml} <- @samples do
      test "detects #{feature}" do
        assert unquote(feature) in FeatureDetector.detect_features(unquote(xml))
      end
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "returns an empty set for a document with no recognised features" do
      assert MapSet.new() == FeatureDetector.detect_features(~s(<scxml version="1.0"/>))
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "detects several features in one document" do
      xml = """
      <scxml>
        <datamodel><data id="x" expr="0"/></datamodel>
        <state id="s1">
          <onentry><assign location="x" expr="1"/></onentry>
          <transition event="go" cond="x" target="s2"/>
        </state>
        <final id="s2"/>
      </scxml>
      """

      features = FeatureDetector.detect_features(xml)

      assert MapSet.subset?(
               MapSet.new([
                 :basic_states,
                 :datamodel,
                 :data_elements,
                 :assign_elements,
                 :onentry_actions,
                 :event_transitions,
                 :conditional_transitions,
                 :final_states
               ]),
               features
             )
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "does not mistake finalize for a final state" do
      xml = ~s(<scxml><state id="s"><invoke><finalize/></invoke></state></scxml>)
      features = FeatureDetector.detect_features(xml)

      assert :finalize_elements in features
      refute :final_states in features
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "does not report eventless or targetless transitions when both are present" do
      xml = ~s(<scxml><state id="s"><transition event="go" target="t"/></state></scxml>)
      features = FeatureDetector.detect_features(xml)

      refute :eventless_transitions in features
      refute :targetless_transitions in features
    end
  end

  # The Phase 1 (st-wju.7) supported set, plus each later bead's registry
  # flips. Keep this in step with the table in
  # docs/plans/260811-st-wju.7-four-function-api-and-corpus-on.md and with
  # every subsequent flip (st-af3.3 adds datamodel/data_elements) - a later
  # accidental flip in the registry should fail here rather than silently
  # widen the corpus.
  @supported_features MapSet.new([
                        :basic_states,
                        :compound_states,
                        :parallel_states,
                        :final_states,
                        :initial_elements,
                        :history_states,
                        :event_transitions,
                        :eventless_transitions,
                        :targetless_transitions,
                        :internal_transitions,
                        :wildcard_events,
                        :onentry_actions,
                        :onexit_actions,
                        :raise_elements,
                        :log_elements,
                        :donedata_elements,
                        # st-af3.3
                        :datamodel,
                        # st-af3.3
                        :data_elements
                      ])

  describe "feature_registry/0" do
    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "supports exactly the current supported feature set" do
      supported =
        FeatureDetector.feature_registry()
        |> Enum.filter(fn {_feature, status} -> status == :supported end)
        |> Enum.map(fn {feature, _status} -> feature end)
        |> MapSet.new()

      assert supported == @supported_features
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "statuses are drawn from the known set" do
      assert Enum.all?(FeatureDetector.feature_registry(), fn {_feature, status} ->
               status in [:supported, :partial, :unsupported]
             end)
    end

    # sabotage: add a feature_registry/0 entry with no matching @samples key -> red
    test "every registry entry has a detection sample" do
      assert MapSet.new(Map.keys(FeatureDetector.feature_registry())) ==
               MapSet.new(Map.keys(@samples))
    end
  end

  describe "validate_features/1" do
    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "accepts an empty set" do
      assert {:ok, features} = FeatureDetector.validate_features(MapSet.new())
      assert MapSet.size(features) == 0
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "reports unsupported features by name" do
      assert {:error, unsupported} =
               FeatureDetector.validate_features(MapSet.new([:assign_elements, :send_elements]))

      assert unsupported == MapSet.new([:assign_elements, :send_elements])
    end

    # sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/ behavior
    test "treats a feature missing from the registry as unsupported" do
      assert {:error, unsupported} =
               FeatureDetector.validate_features(MapSet.new([:not_a_real_feature]))

      assert unsupported == MapSet.new([:not_a_real_feature])
    end
  end
end
