defmodule Statifier.CaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError

  describe "test_scxml/4 feature gate" do
    # sabotage: n/a - asserts the harness's gate is vacuous, no lib/ behavior
    test "every feature the detector can emit is supported or partial" do
      registry = Statifier.FeatureDetector.feature_registry()

      assert {:ok, _detected} =
               Statifier.FeatureDetector.validate_features(MapSet.new(Map.keys(registry)))
    end

    # sabotage: n/a - asserts the harness fails rather than skips, no lib/ behavior
    test "never skips - an unsupported document fails the test" do
      xml = """
      <scxml><state id="s1"><transition cond="ready" target="s1"/></state></scxml>
      """

      assert_raise AssertionError, fn ->
        Statifier.Case.test_scxml(xml, "", ["s1"], [])
      end
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
               Statifier.Case.test_scxml(xml, "moves on event", ["s1"], [
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

      assert :ok = Statifier.Case.test_scxml(xml, "terminates on initialize", ["pass"], [])
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
               Statifier.Case.test_scxml(xml, "terminates on event", ["s1"], [
                 {%{"name" => "go"}, ["pass"]}
               ])
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
          Statifier.Case.test_scxml(xml, "nameless region", ["s1"], [])
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
               Statifier.Case.test_scxml(xml, "send with no delay", ["s1"], [
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

      assert :ok = Statifier.Case.test_scxml(xml, "delayed send reaches its target", ["pass"], [])
    end

    # sabotage: `Statifier.Case`'s `settle_short_timers/2` is changed to
    # return `:ok` unconditionally (a no-op) -> `t2` is sent while the 10ms
    # `ready` timer is still pending, so the b->c transition it would have
    # driven never happens before `t2` is evaluated against "b" instead of
    # "c", landing on "b" (no `t2` transition from there) instead of "d" ->
    # the second `assert_configuration_eventually` reddens. Reverted and
    # confirmed green. This is the harness's own two-wait mechanism, not
    # `lib/` - the same shape `test/scion_tests/delayed_send/send1_test.exs`
    # exercises for real.
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
               Statifier.Case.test_scxml(xml, "send1 shape", ["a"], [
                 {%{"name" => "t1"}, ["b"]},
                 {%{"name" => "t2"}, ["d"]}
               ])
    end

    # sabotage: `Statifier.Case`'s `drain_done_effect/1` is changed to
    # return `nil` unconditionally -> `poll_until_settled/3` never restores
    # `Effect.Done.configuration` onto the raw snapshot, so it reads the
    # post-exit empty configuration instead of `["done"]` -> the assertion
    # reddens. Reverted and confirmed green.
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

      assert :ok = Statifier.Case.test_scxml(xml, "delayed final", ["done"], [])
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
               Statifier.Case.test_scxml(xml, "invoked child drives the parent", ["idle"], [
                 {%{"name" => "start"}, ["done"]}
               ])
    end
  end

  describe "session_required?/1" do
    # sabotage: n/a - asserts the routing predicate itself, not lib/
    # behavior driven through a session.
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

      assert Statifier.Case.session_required?(xml)
    end

    # sabotage: n/a - asserts the routing predicate itself, not lib/
    # behavior driven through a session.
    test "a plain compound document does not route to the session" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
          <state id="s1">
              <transition event="go" target="s2"/>
          </state>
          <state id="s2"/>
      </scxml>
      """

      refute Statifier.Case.session_required?(xml)
    end
  end
end
