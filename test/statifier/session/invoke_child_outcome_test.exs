defmodule Statifier.Session.InvokeChildOutcomeTest do
  use ExUnit.Case, async: false

  # `async: false` for the same reason `invoke_parent_routing_test.exs` gives
  # itself: every test here starts a real child session through
  # `Statifier.start_session/2`'s supervisor.
  #
  # The contract under test: a child chart that
  # can finish several ways reports *which* way through
  # `done.invoke.<invoke_id>`'s data - the top-level `<final>`'s `<donedata>`,
  # per ADR-0051 decision 5 and spec 3.7/5.5 - and nothing else crosses the
  # invoke boundary. The parent routes on `_event.data.<name>` with an
  # unconditioned `done.invoke` transition last, which is the arm a child
  # final carrying no `<donedata>` takes, because `_event.data` reads
  # `:undefined` there. Documented in `docs/extending.md` under "Reading a
  # child's outcome".

  alias Statifier.{Compiler, Lowering, Parser, Session, Validator}

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
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

  # A card-authorization child with three top-level finals. Two are declared
  # outcomes carrying `<donedata><param name="outcome" .../></donedata>`; the
  # third deliberately carries none, so one chart exercises both the routed
  # and the default path depending only on what the parent seeds. Single-
  # spaced, CDATA'd markup in a binary, exactly like the sibling invoke
  # tests' own child charts.
  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="check" version="1.0" datamodel="predicator"><datamodel><data id="amount"/></datamodel><state id="check"><transition cond="amount > 100" target="declined"/><transition cond="amount > 0" target="approved"/><transition target="abandoned"/></state><final id="approved"><donedata><param name="outcome" expr="'approved'"/></donedata></final><final id="declined"><donedata><param name="outcome" expr="'declined'"/></donedata></final><final id="abandoned"/></scxml>)

  defp content_body(xml), do: "<content><![CDATA[#{xml}]]></content>"

  # The parent shape the ruling pins: one conditioned `done.invoke.<id>`
  # transition per declared outcome, reading `_event.data.outcome`, and an
  # unconditioned `done.invoke.<id>` transition LAST as the default arm.
  # `saw_undefined` records what `_event.data` reads as on that default arm,
  # so the `:undefined` half of the ruling is asserted from inside the chart
  # rather than from the delivered event's Elixir-side shape alone.
  defp parent_xml(amount) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorizing">
        <datamodel>
            <data id="saw_undefined" expr="false"/>
        </datamodel>
        <state id="authorizing">
            <invoke id="auth" type="scxml">
                <param name="amount" expr="#{amount}"/>
                #{content_body(@child_xml)}
            </invoke>
            <transition event="done.invoke.auth" cond="_event.data.outcome == 'approved'" target="captured"/>
            <transition event="done.invoke.auth" cond="_event.data.outcome == 'declined'" target="rejected"/>
            <transition event="done.invoke.auth" target="unhandled"/>
        </state>
        <state id="captured"/>
        <state id="rejected"/>
        <state id="unhandled">
            <onentry>
                <assign location="saw_undefined" expr="_event.data === undefined"/>
            </onentry>
        </state>
    </scxml>
    """
  end

  defp run_parent(amount, expected_state) do
    {:ok, parent} = Session.start_link(compile!(parent_xml(amount)))

    wait_for_status(parent, fn s -> s.configuration == MapSet.new([expected_state]) end)

    parent
  end

  describe "a child chart with one top-level final per declared outcome" do
    # sabotage: `Statifier.Session`'s `return_done_event(:done, %State{
    # invoked_by: {parent_pid, invoke_id}} = state)` clause passes `nil`
    # instead of `state.done_effect.donedata` -> the child's `<donedata>`
    # stops crossing the boundary, both conditioned arms fall through, and
    # every run lands in "unhandled", so both tests below redden on the
    # configuration they wait for. It reddens the `saw_undefined` test in the
    # next describe too, and instructively: an explicitly `nil` donedata is
    # not the absent one a `<final>` without `<donedata>` carries, so
    # `_event.data === undefined` reads false there. Reverted and confirmed
    # green.
    test "the approved final's donedata routes the parent to its matching state" do
      parent = run_parent(25, "captured")

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["name"] == "done.invoke.auth"
      assert event["invokeid"] == "auth"
      assert event["data"] == %{"outcome" => "approved"}
    end

    # sabotage: as above - the same `return_done_event/2` mutation drops this
    # run's `"declined"` payload too, landing it in "unhandled" instead of
    # "rejected". Reverted and confirmed green.
    test "the declined final's donedata routes the parent to its own matching state" do
      parent = run_parent(250, "rejected")

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["invokeid"] == "auth"
      assert event["data"] == %{"outcome" => "declined"}
    end
  end

  describe "a child final carrying no <donedata>" do
    # sabotage: `Statifier.Invoke.Answer.done/3` stamps
    # `data: %{"outcome" => "approved"}` instead of the `donedata` it is
    # handed -> a final with no `<donedata>` now arrives carrying data, the
    # first conditioned arm matches, and the parent lands in "captured"
    # instead of "unhandled" - reddening the wait below before the
    # `saw_undefined` assertion is even reached. Reverted and confirmed
    # green.
    test "takes the unconditioned done.invoke arm, with _event.data undefined" do
      parent = run_parent(0, "unhandled")

      datamodel = Session.snapshot(parent).datamodel

      # Recorded by "unhandled"'s own <onentry>, while the done event was
      # still `_event`: the payload-less final really does arrive with
      # `_event.data` reading `:undefined`, which is what makes the two
      # conditioned arms above fall through to this one.
      assert datamodel["saw_undefined"] == true
    end

    # sabotage: the same `Statifier.Invoke.Answer.done/3` mutation as above
    # - a payload-less final now arrives carrying data, so the first conditioned
    # arm matches and evaluates cleanly, no `error.execution` is ever raised,
    # and the wait for "unhandled" never comes true. Reverted and confirmed
    # green.
    test "the loose == conds against an undefined payload raise error.execution" do
      # Worth pinning because it is the one rough edge of the ruled parent
      # shape: `_event.data.outcome == 'approved'` evaluates to `:undefined`
      # rather than `false` when the child final carried no `<donedata>`, and
      # a non-boolean cond is false plus `error.execution` (spec 5.9.1). The
      # routing is unaffected - the default arm still fires, as the test
      # above proves - but the parent does see the error event afterwards.
      # Spelling the conds `===` instead evaluates to a clean `false`.
      parent = run_parent(0, "unhandled")

      assert Session.snapshot(parent).datamodel["_event"]["name"] == "error.execution"
    end
  end
end
