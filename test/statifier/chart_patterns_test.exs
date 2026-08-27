defmodule Statifier.ChartPatternsTest do
  @moduledoc """
  Pins the runnable example in `docs/chart-patterns.md`: the park/retry and
  fail-fast reactions to a host-delivered capture verdict. The chart here is
  the document printed in that guide - if one changes, change both.
  """

  use Statifier.Testing.Case, async: true

  # The example chart from docs/chart-patterns.md, verbatim: a three-attempt
  # retry budget spelled as states (capturing -> retrying_once ->
  # last_attempt), backoff visible on the park states' <send delay> values,
  # and explicit fail-fast arrows for the permanent verdicts - including the
  # `error.communication` arrow that ADR-0068's
  # `error.communication.invoke.<invoke_id>` matches by prefix.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="capturing">
      <state id="capturing">
          <transition event="capture.succeeded" target="settled"/>
          <transition event="capture.deferred" target="parked_once"/>
          <transition event="card.revoked" target="needs_attention"/>
          <transition event="error.execution" target="needs_attention"/>
          <transition event="error.communication" target="needs_attention"/>
      </state>
      <state id="parked_once">
          <onentry>
              <send event="retry" delay="10ms"/>
          </onentry>
          <transition event="retry" target="retrying_once"/>
          <transition event="card.revoked" target="needs_attention"/>
      </state>
      <state id="retrying_once">
          <transition event="capture.succeeded" target="settled"/>
          <transition event="capture.deferred" target="parked_twice"/>
          <transition event="card.revoked" target="needs_attention"/>
          <transition event="error.execution" target="needs_attention"/>
          <transition event="error.communication" target="needs_attention"/>
      </state>
      <state id="parked_twice">
          <onentry>
              <send event="retry" delay="20ms"/>
          </onentry>
          <transition event="retry" target="last_attempt"/>
          <transition event="card.revoked" target="needs_attention"/>
      </state>
      <state id="last_attempt">
          <transition event="capture.succeeded" target="settled"/>
          <transition event="capture.deferred" target="needs_attention"/>
          <transition event="card.revoked" target="needs_attention"/>
          <transition event="error.execution" target="needs_attention"/>
          <transition event="error.communication" target="needs_attention"/>
      </state>
      <final id="settled"/>
      <final id="needs_attention"/>
  </scxml>
  """

  describe "the docs/chart-patterns.md example chart" do
    # sabotage: `Statifier.Session`'s `perform_instruction({:schedule, _, _,
    # _, _, _}, state, _override)` clause is changed to `state` (drops the
    # instruction instead of scheduling the timer) -> the park state's retry
    # timer never fires, so the first deferral step settles on "parked_once"
    # instead of the expected "retrying_once" -> red. Reverted and confirmed
    # green.
    test "park/retry: the budget exhausts into the needs_attention final state" do
      test_scxml(@chart, "three deferrals exhaust the budget", ["capturing"], [
        {%{"name" => "capture.deferred"}, ["retrying_once"]},
        {%{"name" => "capture.deferred"}, ["last_attempt"]},
        {%{"name" => "capture.deferred"}, ["needs_attention"]}
      ])
    end

    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2`
    # returns `{machine_state, []}` instead of its enabled set ->
    # `card.revoked` drives no transition, the chart never leaves
    # "capturing" -> red. Reverted and confirmed green.
    test "fail-fast: a revoked card routes straight to needs_attention" do
      test_scxml(@chart, "revoked fails fast", ["capturing"], [
        {%{"name" => "card.revoked"}, ["needs_attention"]}
      ])
    end

    # sabotage: `Statifier.Interpreter.NameMatch`'s descriptor prefix arm is
    # narrowed to exact equality -> `error.communication.invoke.capture` no
    # longer matches the chart's plain `error.communication` arrow, so the
    # run stays in "capturing" -> red. Reverted and confirmed green.
    test "fail-fast: a permanently failed capture invocation parks the same way" do
      test_scxml(@chart, "exhausted invocation parks", ["capturing"], [
        {%{"name" => "error.communication.invoke.capture"}, ["needs_attention"]}
      ])
    end
  end
end
