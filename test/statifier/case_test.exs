defmodule Statifier.Testing.CaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError
  alias Statifier.Testing.{Case, FeatureDetector}

  describe "test_scxml/4 feature gate" do
    # sabotage: validate_features/1 treats an unknown atom as :supported
    # (Map.get's default falls back to :supported instead of :unsupported)
    # -> red
    test "the feature gate is vacuous by construction - no document can currently reach the flunk" do
      registry = FeatureDetector.feature_registry()

      assert {:ok, _detected} =
               FeatureDetector.validate_features(MapSet.new(Map.keys(registry)))

      assert {:error, unsupported} =
               FeatureDetector.validate_features(MapSet.new([:not_a_real_feature]))

      assert unsupported == MapSet.new([:not_a_real_feature])
    end

    # `Statifier.Testing.Case`'s flunk branch is unreachable today (the test
    # above), so the runner's gate cannot be asserted by driving a real
    # document through it. What can be asserted is the contract the flunk
    # branch depends on: `validate_features/1`'s `{:error, set}` names only
    # the features it rejected, not every feature the document detected -
    # exactly the set the runner's flunk message would interpolate.
    #
    # sabotage: `validate_features/1`'s `Enum.reject/2` is replaced with
    # `detected_features` itself whenever the result is non-empty (the
    # rejected set leaks the whole detected set instead of only the
    # unsupported members) -> `:basic_states` is named alongside the
    # synthetic feature -> red
    test "never skips - the error set names only the unsupported features, not every detected one" do
      detected = MapSet.new([:basic_states, :not_a_real_feature])

      assert {:error, unsupported} = FeatureDetector.validate_features(detected)
      assert unsupported == MapSet.new([:not_a_real_feature])
    end
  end

  describe "test_scxml/4 end to end" do
    # sabotage: select_transitions/2 discards its enabled set -> red
    test "drives a compound document through compile, initialize, and one event" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="s2"/>
          </state>
          <state id="s2"/>
      </scxml>
      """

      assert :ok =
               Case.test_scxml(xml, "moves on event", ["s1"], [
                 {%{"name" => "go"}, ["s2"]}
               ])
    end
  end

  describe "test_scxml/4 terminal configuration" do
    # sabotage: exit_interpreter/1 populates Effect.Done's configuration from
    # the post-fold machine_state.configuration instead of
    # configuration_at_exit -> the effect comes back with an empty set -> red
    test "asserts against the configuration at exit when the initial configuration terminates" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pass">
          <final id="pass"/>
      </scxml>
      """

      assert :ok = Case.test_scxml(xml, "terminates on initialize", ["pass"], [])
    end

    # sabotage: assert_configuration/3's observed_state_chart/2 always returns
    # state_chart unchanged (drops the {:done, _} branch) -> the terminal
    # assertion sees the post-exit empty configuration -> red
    test "asserts against the configuration at exit when an event terminates the chart" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="pass"/>
          </state>
          <final id="pass"/>
      </scxml>
      """

      assert :ok =
               Case.test_scxml(xml, "terminates on event", ["s1"], [
                 {%{"name" => "go"}, ["pass"]}
               ])
    end

    # sabotage: Statifier.Testing.Case's send_event/2 returns the unchanged
    # state chart on {:error, :not_running} instead of flunking -> red
    test "flunks sending an event to a chart that has already terminated" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pass">
          <final id="pass"/>
      </scxml>
      """

      error =
        assert_raise AssertionError, fn ->
          Case.test_scxml(xml, "event after termination", ["pass"], [
            {%{"name" => "go"}, ["pass"]}
          ])
        end

      assert error.message =~ "state chart that has terminated"
    end
  end

  describe "test_scxml/4 malformed documents" do
    # sabotage: parse_document/1's {:error, errors} clause raises
    # ArgumentError instead of calling flunk/1 -> assert_raise's exception
    # type no longer matches ExUnit.AssertionError -> red
    test "flunks when the document fails to compile" do
      xml = "<not-scxml/>"

      error =
        assert_raise AssertionError, fn ->
          Case.test_scxml(xml, "malformed document", [], [])
        end

      assert error.message =~ "did not compile"
    end
  end

  describe "test_scxml/4 nameless-leaf assertion" do
    # sabotage: Statifier.active_leaf_states/1 keeps nil ids instead of
    # rejecting them -> raw and translated sizes now match, so
    # assert_every_leaf_named/2 does not raise; the outer AssertionError
    # instead comes from the ordinary equality check (actual now contains
    # nil), so this test's message assertion is what goes red, not the
    # assert_raise itself -> red
    test "raises naming the count when an active leaf has no id" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
          <parallel id="p">
              <state id="s1"/>
              <state/>
          </parallel>
      </scxml>
      """

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Case.test_scxml(xml, "nameless region", ["s1"], [])
        end

      assert error.message =~ "active leaf state(s) have no id"
    end
  end

  describe "test_scxml/4 session path" do
    # sabotage: `Statifier.Session`'s `perform_instruction({:enqueue_event,
    # _}, state, _override)` clause (the no-delay self-send route) is
    # changed to `state` (drops the event instead of enqueuing it) -> the
    # onentry `<send event="go"/>` in "s2" never reaches this session's own
    # queue, so the transition to "s3" never fires and the wait below times
    # out at "s2". Reverted and confirmed green.
    test "a <send> with no delay reaches its expected configuration" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="start" target="s2"/>
          </state>
          <state id="s2">
              <onentry>
                  <send event="go"/>
              </onentry>
              <transition event="go" target="s3"/>
          </state>
          <state id="s3"/>
      </scxml>
      """

      assert :ok =
               Case.test_scxml(xml, "send with no delay", ["s1"], [
                 {%{"name" => "start"}, ["s3"]}
               ])
    end

    # sabotage: `Statifier.Session`'s `perform_instruction({:schedule, _, _,
    # _, _, _}, state, _override)` clause is changed to `state` (drops the
    # instruction instead of calling `Process.send_after/3`) -> the delayed
    # `go` event never fires, so the session never leaves "waiting" and the
    # wait below times out. Reverted and confirmed green.
    test "a document whose only route to its expected configuration is a delayed send reaches it" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
          <state id="waiting">
              <onentry>
                  <send event="go" delay="20ms"/>
              </onentry>
              <transition event="go" target="pass"/>
          </state>
          <state id="pass"/>
      </scxml>
      """

      assert :ok = Case.test_scxml(xml, "delayed send reaches its target", ["pass"], [])
    end

    # sabotage: `Statifier.Testing.Case`'s `settle_short_timers/2` is changed
    # to return `:ok` unconditionally (a no-op) -> `t2` is sent while the
    # 10ms `ready` timer is still pending, so the b->c transition it would
    # have driven never happens before `t2` is evaluated against "b" instead
    # of "c", landing on "b" (no `t2` transition from there) instead of "d"
    # -> the second `assert_configuration_eventually` reddens. Reverted and
    # confirmed green. This is the harness's own two-wait mechanism, not
    # `lib/` interpreter behavior - the same shape
    # `test/scion_tests/delayed_send/send1_test.exs` exercises for real.
    test "settle_short_timers/1 drains a load-bearing intermediate delay before the next event" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="t1" target="b">
                  <send event="ready" delay="10ms"/>
              </transition>
          </state>
          <state id="b">
              <transition event="ready" target="c"/>
          </state>
          <state id="c">
              <transition event="t2" target="d"/>
          </state>
          <state id="d"/>
      </scxml>
      """

      assert :ok =
               Case.test_scxml(xml, "send1 shape", ["a"], [
                 {%{"name" => "t1"}, ["b"]},
                 {%{"name" => "t2"}, ["d"]}
               ])
    end

    # sabotage: `Statifier.Testing.Case`'s `drain_done_effect/1` is changed
    # to return `nil` unconditionally -> `poll_until_settled/3` never
    # restores `Effect.Done.configuration` onto the raw snapshot, so it
    # reads the post-exit empty configuration instead of `["done"]` -> the
    # assertion reddens. Reverted and confirmed green.
    test "a <final> reached through a delayed send restores the configuration at exit" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
          <state id="idle">
              <onentry>
                  <send event="go" delay="20ms"/>
              </onentry>
              <transition event="go" target="done"/>
          </state>
          <final id="done"/>
      </scxml>
      """

      assert :ok = Case.test_scxml(xml, "delayed final", ["done"], [])
    end

    # A permanent 200ms guard timer keeps `pending_timers != 0` for the whole
    # 50ms `:configuration_deadline_ms` window below, so `poll_until_settled/4`
    # can only exit through the deadline clause - never through the "cannot
    # change again" stability exit, which needs `pending_timers == 0`.
    #
    # sabotage: `poll_until_settled/4`'s
    # `System.monotonic_time(:millisecond) >= deadline -> observed` clause is
    # changed to `System.monotonic_time(:millisecond) >= :infinity -> observed`
    # (a condition that can never be true) -> the loop never exits on its own
    # and the test hangs instead of failing cleanly, so it was run under a
    # shell-level `timeout` to observe the red. Reverted and confirmed green.
    test "exits the poll on its deadline when the expected configuration is never reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loop">
          <state id="loop">
              <onentry>
                  <send event="tick" delay="200ms"/>
              </onentry>
              <transition event="tick" target="loop"/>
          </state>
      </scxml>
      """

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Case.test_scxml(xml, "unreachable configuration", ["unreachable"], [],
            configuration_deadline_ms: 50
          )
        end

      assert error.message =~ "Expected active states"
      assert error.message =~ "unreachable"
      assert error.message =~ "loop"
    end

    # The invoke sits behind a transition rather than on the initial state:
    # `Statifier.start_session/2`'s own `DynamicSupervisor.start_child/2`
    # call is still in flight (waiting on this session's own `init/1`) until
    # `start_session/2` returns, so a child started synchronously *during*
    # `init/1` would ask the same, still-busy `DynamicSupervisor` for a
    # second child and deadlock both. Gating the `<invoke>` behind "start"
    # lets it fire from an ordinary `handle_cast`, well after `init/1` (and
    # the outer `start_session/2` call) has already returned - a real
    # `Statifier.Session` limitation the corpus's own initial-state
    # `<invoke>` shape is coincidentally shielded from today only because
    # its content fails to compile first (`docs/adr/0041-...`).
    #
    # sabotage: `Statifier.Session`'s `deliver(:parent, event, _effect,
    # %State{invoked_by: {parent_pid, invoke_id}}, _override)` clause is
    # changed to `state` (drops the event instead of casting it to the
    # parent) -> the child's onentry `<send target="#_parent">` never
    # reaches the parent, so it never leaves "waiting" and the wait below
    # times out. Reverted and confirmed green.
    test "an <invoke> with inline <content> whose child drives the parent to its expected configuration" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
          <state id="idle">
              <transition event="start" target="waiting"/>
          </state>
          <state id="waiting">
              <invoke type="scxml">
                  <content>
                      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="run">
                          <state id="run">
                              <onentry>
                                  <send target="#_parent" event="go"/>
                              </onentry>
                          </state>
                      </scxml>
                  </content>
              </invoke>
              <transition event="go" target="done"/>
          </state>
          <state id="done"/>
      </scxml>
      """

      assert :ok =
               Case.test_scxml(xml, "invoked child drives the parent", ["idle"], [
                 {%{"name" => "start"}, ["done"]}
               ])
    end
  end

  describe "session_required?/1" do
    # sabotage: session_required?/1 drops :invoke_elements from
    # @session_features -> a document whose only session-requiring feature
    # is <invoke> stops routing to the session -> red
    test "a document detecting a session feature routes to the session" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <onentry>
                  <send event="go"/>
              </onentry>
          </state>
      </scxml>
      """

      assert Case.session_required?(xml)
    end

    # sabotage: session_required?/1's MapSet.t() clause is changed to
    # `Enum.any?(@session_features, fn _ -> true end)` (ignores the detected
    # set entirely) -> a document with no session feature now routes to the
    # session too -> red
    test "a plain compound document does not route to the session" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="s2"/>
          </state>
          <state id="s2"/>
      </scxml>
      """

      refute Case.session_required?(xml)
    end
  end
end
