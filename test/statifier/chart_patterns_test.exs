defmodule Statifier.ChartPatternsTest do
  @moduledoc """
  Pins the runnable example in `docs/chart-patterns.md`: the park/retry and
  fail-fast reactions to a host-delivered external-resource verdict. The
  chart here is the document printed in that guide - if one changes, change
  both.
  """

  use Statifier.Testing.Case, async: true

  # The example chart from docs/chart-patterns.md, verbatim: a three-attempt
  # retry budget spelled as states (requesting -> retrying_once ->
  # last_attempt), backoff visible on the park states' <send delay> values,
  # and explicit fail-fast arrows for the permanent verdict.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="requesting">
      <state id="requesting">
          <transition event="resource.ready" target="succeeded"/>
          <transition event="resource.paused" target="parked_once"/>
          <transition event="resource.revoked" target="failed"/>
          <transition event="error.execution" target="failed"/>
      </state>
      <state id="parked_once">
          <onentry>
              <send event="retry" delay="10ms"/>
          </onentry>
          <transition event="retry" target="retrying_once"/>
          <transition event="resource.revoked" target="failed"/>
      </state>
      <state id="retrying_once">
          <transition event="resource.ready" target="succeeded"/>
          <transition event="resource.paused" target="parked_twice"/>
          <transition event="resource.revoked" target="failed"/>
          <transition event="error.execution" target="failed"/>
      </state>
      <state id="parked_twice">
          <onentry>
              <send event="retry" delay="20ms"/>
          </onentry>
          <transition event="retry" target="last_attempt"/>
          <transition event="resource.revoked" target="failed"/>
      </state>
      <state id="last_attempt">
          <transition event="resource.ready" target="succeeded"/>
          <transition event="resource.paused" target="failed"/>
          <transition event="resource.revoked" target="failed"/>
          <transition event="error.execution" target="failed"/>
      </state>
      <final id="succeeded"/>
      <final id="failed"/>
  </scxml>
  """

  describe "the docs/chart-patterns.md example chart" do
    # sabotage: `Statifier.Session`'s `perform_instruction({:schedule, _, _,
    # _, _, _}, state, _override)` clause is changed to `state` (drops the
    # instruction instead of scheduling the timer) -> the park state's retry
    # timer never fires, so the first pause step settles on "parked_once"
    # instead of the expected "retrying_once" -> red. Reverted and confirmed
    # green.
    test "park/retry: the budget exhausts into the failed final state" do
      test_scxml(@chart, "three pauses exhaust the budget", ["requesting"], [
        {%{"name" => "resource.paused"}, ["retrying_once"]},
        {%{"name" => "resource.paused"}, ["last_attempt"]},
        {%{"name" => "resource.paused"}, ["failed"]}
      ])
    end

    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2`
    # returns `{machine_state, []}` instead of its enabled set ->
    # `resource.revoked` drives no transition, the chart never leaves
    # "requesting" -> red. Reverted and confirmed green.
    test "fail-fast: a revoked-style verdict routes straight to failed" do
      test_scxml(@chart, "revoked fails fast", ["requesting"], [
        {%{"name" => "resource.revoked"}, ["failed"]}
      ])
    end
  end
end
