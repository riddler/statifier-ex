defmodule Statifier.Testing.Case do
  @moduledoc """
  Test case template for the SCION and W3C conformance corpora.

  Test-side surface for chart authors, versioned with the engine: no module in
  `lib/` outside `Statifier.Testing.*` may reference anything inside it, so the
  engine never consults the test harness to decide behavior (ADR-0052,
  amending ADR-0006). This module is also the supported entry point for a
  downstream application testing its own charts, not only the corpus's driver
  - `use Statifier.Testing.Case` works the same way outside this repository as
  it does inside it.

  Every generated corpus test goes through `test_scxml/4` and nothing else, so
  this module is the entire coupling surface between the corpus and the library
  (ADR-0006). It needs exactly four things from `Statifier` to *drive* a chart:

  1. parse an SCXML document,
  2. build and initialize a state chart from it,
  3. send an event synchronously and get the next state chart back,
  4. read the active leaf-state set.

  Each of those lives in its own private helper below - `parse_document/1`,
  `initialize/1`, `send_event/2`, `active_leaf_states/1` - and each is a thin
  adapter over `Statifier`'s four-function API (`Statifier.compile/1`,
  `Statifier.initialize/2`, `Statifier.send_event/2`,
  `Statifier.active_leaf_states/1`): unwrapping the `{:ok, _}` / `{:error, _}`
  tuples and translating the corpus's event map into the shape `Statifier`
  expects. The four-function contract stays a hard constraint on the library
  surface rather than something the corpus can widen.

  The assertion path reads two more things, both because a terminated chart's
  `configuration` is empty by construction (`exit_interpreter/1`, Appendix D)
  and the harness still has to say what the chart's leaves were at exit:

  - `initialize/1` and `send_event/2` now also return the call's effect list.
    `assert_configuration/3` looks for a `{:done, _}` effect in it and, when
    found, restores that effect's `configuration` field - `Effect.Done`
    carries the terminal configuration - onto the `%MachineState{}` before
    reading leaves off it -
    so the terminal position is observed instead of the post-exit emptiness.
    This is still driving-side plumbing routed to the assertion, not a fifth
    driving function.
  - `Statifier.MachineState.active_leaf_states/1` (the untranslated,
    index-keyed version behind `Statifier.active_leaf_states/1`) is read
    directly by `assert_every_leaf_named/2` to compare its size against the
    id-translated set, catching a nameless active leaf that the id-based
    comparison would silently drop. This is an inspection of a value the
    harness already holds, not a new way to drive the chart.

  Documents using features v2 does not support flunk with the feature named
  (`Statifier.Testing.FeatureDetector`) - they never skip, so an unimplemented
  feature can never masquerade as a passing test. Both suites are excluded by
  default (`:scion`, `:scxml_w3`), so `mix test` stays green while
  `test.regression`'s ratchet is the thing that grows.

  ## Two driving paths, one closed contract

  `test_scxml/4` routes each document, on the same detected feature set, to
  one of two private paths. Documents that need real delivery, wall-clock
  timers, or child sessions (`@session_features` below) drive through a
  `Statifier.Session`; every other document drives synchronously through the
  four functions this moduledoc opens with. The session path keeps
  `Statifier.compile/1` and `Statifier.active_leaf_states/1` exactly as they
  were and replaces the other two with five: `initialize` becomes
  `Statifier.start_session/2`, `send_event` becomes
  `Statifier.Session.send_event/2`, and driving a live session additionally
  needs `Statifier.Session.snapshot/1` to read a configuration,
  `Statifier.Session.status/1` to know when it has settled, and
  `Statifier.Session.stop/2` to tear it down. Nine functions across the two
  paths, enumerated in ADR-0006 and closed: adding a tenth, or a third
  driving path, reopens that record rather than being a harness change.
  Either way the corpus still cannot widen the library surface, because every
  one of the nine is public API carried by its own record.

  v1's `StateMachine` and logging helpers are deliberately not ported: the
  subsystems they drove do not exist in v2, and reintroducing them here would
  grow the coupling surface this module exists to hold flat.
  """

  use ExUnit.CaseTemplate

  alias Statifier.{MachineState, Session}
  alias Statifier.Testing.FeatureDetector

  using do
    quote do
      import unquote(__MODULE__)
    end
  end

  # These ten atoms are exactly the ones whose semantics need a running
  # session: delivery to an external queue, wall-clock timers, and child
  # sessions. Every other document reaches the same configuration through
  # the four-function synchronous path, which stays the default - the files
  # already in the ratchet detect none of these and keep driving exactly as
  # before.
  @session_features [
    :send_elements,
    :send_content_elements,
    :send_param_elements,
    :send_delay_expressions,
    :send_idlocation,
    :event_expressions,
    :target_expressions,
    :cancel_elements,
    :invoke_elements,
    :finalize_elements
  ]

  # The corpus's delay values fall into two populations: load-bearing
  # intermediate delays (1ms, 2ms, 10ms) that a later assertion depends on
  # having fired, and guard sends (`<send event="timeout" delay="5s"/>`) that a
  # passing run must never let fire. 100ms separates them cleanly, so waiting
  # out a pending timer before the *next* event drains the first population and
  # never the second. Costs nothing when no timer is pending, which is most of
  # the corpus.
  @settle_window_ms 100

  # The longest load-bearing delay in the corpus is 1.5s
  # (mandatory/cancel/test208). 4s clears it with margin. This bounds only the
  # wrong answer: a chart that cannot change again exits the poll immediately.
  @configuration_deadline_ms 4_000
  @poll_interval_ms 5

  @doc """
  Tests SCXML state chart behavior.

  - `xml` - SCXML document string
  - `description` - test description, for debugging
  - `expected_initial_config` - active leaf state IDs expected after initialize
  - `events` - list of `{event_map, expected_states}` tuples, where `event_map`
    carries the event name under `"name"`

  Flunks with the feature named if the document depends on an SCXML feature v2
  does not support yet, rather than reporting a false pass.
  """
  @spec test_scxml(
          xml :: String.t(),
          description :: String.t(),
          expected_initial_config :: [String.t()],
          events :: [{map(), [String.t()]}]
        ) :: :ok
  def test_scxml(xml, description, expected_initial_config, events) do
    detected = validate_features!(xml, description)

    if session_required?(detected) do
      drive_through_session(xml, expected_initial_config, events)
    else
      drive_synchronously(xml, expected_initial_config, events)
    end
  end

  @doc """
  Whether a document needs the session layer to reach its expected
  configurations. Public so the routing decision can be asserted directly;
  `test_scxml/4` is the only caller in the corpus.
  """
  @spec session_required?(xml_or_detected :: String.t() | MapSet.t(atom())) :: boolean()
  def session_required?(xml) when is_binary(xml),
    do: xml |> FeatureDetector.detect_features() |> session_required?()

  def session_required?(%MapSet{} = detected),
    do: Enum.any?(@session_features, &MapSet.member?(detected, &1))

  defp drive_synchronously(xml, expected_initial_config, events) do
    {state_chart, effects} = xml |> parse_document() |> initialize()

    assert_configuration(state_chart, effects, expected_initial_config)

    _final_state_chart =
      Enum.reduce(events, state_chart, fn {event_map, expected_states}, current_state_chart ->
        {next_state_chart, next_effects} = send_event(current_state_chart, event_map)
        assert_configuration(next_state_chart, next_effects, expected_states)
        next_state_chart
      end)

    :ok
  end

  # A corpus document that needs a session needs the *registered* runtime:
  # `<invoke>` starts children through `Statifier.start_session/2` and
  # `#_scxml_<sessionid>` targets resolve through `Statifier.Registry`.
  # Sessions started this way are unlinked and `restart: :temporary`, so the
  # harness stops each one itself - which is also what cancels any guard timer
  # still pending when the test ends (`terminate/2`, spec 6.2's
  # discard-on-termination).
  defp drive_through_session(xml, expected_initial_config, events) do
    machine = parse_document(xml)
    {:ok, session} = Statifier.start_session(machine, subscribers: [self()])

    try do
      assert_configuration_eventually(session, expected_initial_config)

      Enum.each(events, fn {%{"name" => name}, expected_states} ->
        settle_short_timers(session)
        :ok = Session.send_event(session, name)
        assert_configuration_eventually(session, expected_states)
      end)
    after
      Session.stop(session)
    end

    :ok
  end

  # Polls `Session.status/1` for the counters and `Session.snapshot/1` for the
  # `%MachineState{}` the leaf read needs, draining any
  # `{:statifier, _sid, {:effect, {:done, done}}}` message from the mailbox so
  # a terminated chart's configuration is restored by the same
  # `observed_state_chart/2` the synchronous path uses. Stops on the first of:
  # the observed leaf set equalling the expectation; the session being unable
  # to change again (`status != :running`, or `queued_events == 0 and
  # pending_timers == 0` on two consecutive polls - `poll_until_settled/4`'s
  # own comment explains the debounce); or the deadline. Then performs the
  # ordinary `assert_every_leaf_named/2` plus set-equality assertion, so a
  # failure message is identical in shape to the synchronous path's.
  defp assert_configuration_eventually(session, expected_state_ids) do
    expected = MapSet.new(expected_state_ids)
    deadline = System.monotonic_time(:millisecond) + @configuration_deadline_ms

    observed = poll_until_settled(session, expected, deadline)
    actual = active_leaf_states(observed)

    assert_every_leaf_named(observed, actual)

    assert expected == actual,
           "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"
  end

  defp poll_until_settled(session, expected, deadline),
    do: poll_until_settled(session, expected, deadline, false)

  # `was_stable?` debounces the "cannot change again" exit by one poll
  # interval, for two distinct reasons folded into one flag:
  #
  # - An invoked child's own reply (`<send target="#_parent">`) lands on
  #   this session's queue through a separate process's cast, which can
  #   arrive a hair after the parent's own `queued_events == 0 and
  #   pending_timers == 0` moment - the parent has nothing outstanding *of
  #   its own* at that instant, but is not yet done changing.
  # - `drain_done_effect/1` and `Session.status/1` are two separate calls;
  #   a session that halts *between* them has already answered `:done` by
  #   the second call while the terminal `{:done, _}` broadcast this
  #   process's mailbox is racing to deliver has not yet arrived, so
  #   trusting `status != :running` on that exact poll would restore
  #   nothing and observe the post-exit empty configuration instead.
  #
  # Requiring the same stable reading twice in a row, one
  # `@poll_interval_ms` apart, gives either race a full interval to resolve
  # before this loop trusts it and stops early.
  defp poll_until_settled(session, expected, deadline, was_stable?) do
    done_effect = drain_done_effect(session)
    observed = observed_state_chart(Session.snapshot(session), List.wrap(done_effect))
    status = Session.status(session)

    stable? =
      status.status != :running or
        (status.queued_events == 0 and status.pending_timers == 0)

    cond do
      active_leaf_states(observed) == expected ->
        observed

      stable? and was_stable? ->
        observed

      System.monotonic_time(:millisecond) >= deadline ->
        observed

      true ->
        Process.sleep(@poll_interval_ms)
        poll_until_settled(session, expected, deadline, stable?)
    end
  end

  # `settle_short_timers/1` returns immediately when `status.pending_timers ==
  # 0`, and otherwise polls until it reaches 0 or `@settle_window_ms` elapses -
  # draining the load-bearing intermediate delays (1ms/2ms/10ms) before the
  # next event is sent, and never a guard send timed to outlive the test.
  defp settle_short_timers(session) do
    deadline = System.monotonic_time(:millisecond) + @settle_window_ms
    settle_short_timers(session, deadline)
  end

  defp settle_short_timers(session, deadline) do
    if Session.status(session).pending_timers == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :ok
      else
        Process.sleep(@poll_interval_ms)
        settle_short_timers(session, deadline)
      end
    end
  end

  # `session` is unused - the subscriber mailbox only ever carries effects
  # from the one session this harness started and subscribed to - kept as a
  # parameter anyway so every poll-loop helper in this module takes the
  # session it acts on, rather than reading ambient process state.
  defp drain_done_effect(_session) do
    # This module is `Statifier.Testing`, the test-side surface the same
    # `lib/` tree now carries (ADR-0052), not the core: it drives a session
    # from outside and reads its own subscriber mailbox. Draining here rather
    # than returning an effect is the point - there is no interpreter above
    # this frame to run one. ADR-0003 scopes "no side effects in the pure
    # core" to the engine, so this is the escape, not a violation (ADR-0003).
    receive do
      {:statifier, _session_id, {:effect, {:done, _done} = effect}} -> effect
    after
      0 -> nil
    end
  end

  defp validate_features!(xml, description) do
    detected = FeatureDetector.detect_features(xml)

    case FeatureDetector.validate_features(detected) do
      {:ok, _supported} ->
        detected

      {:error, unsupported} ->
        flunk("""
        Test depends on unsupported SCXML features: #{format_features(unsupported)}

        This test cannot pass until these features are implemented in Statifier.
        Detected features: #{format_features(detected)}

        For which features are supported, see Statifier.Testing.FeatureDetector.feature_registry/0
        Test description: #{description}
        """)
    end
  end

  defp format_features(features), do: features |> Enum.sort() |> Enum.join(", ")

  defp assert_configuration(state_chart, effects, expected_state_ids) do
    expected = MapSet.new(expected_state_ids)
    observed = observed_state_chart(state_chart, effects)
    actual = active_leaf_states(observed)

    assert_every_leaf_named(observed, actual)

    assert expected == actual,
           "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"
  end

  # A terminated chart has an empty configuration by construction
  # (exit_interpreter/1, Appendix D) - the position it held at exit rides the
  # core :done effect instead (Effect.Done.configuration). Restoring it onto
  # the MachineState keeps the index-to-id translation inside
  # Statifier.active_leaf_states/1, where ADR-0005 puts it, rather than
  # reimplementing that translation here.
  defp observed_state_chart(state_chart, effects) do
    case Enum.find(effects, &match?({:done, _payload}, &1)) do
      {:done, done} -> %{state_chart | configuration: done.configuration}
      nil -> state_chart
    end
  end

  # Statifier.active_leaf_states/1 drops nil ids - correct, since no
  # expectation can name an unnamed state - but that would let an anonymous
  # active leaf pass unobserved while the named ones match, and the ratchet
  # would then defend the false pass forever. Cardinality is the one thing
  # the harness can check without naming what it cannot name.
  defp assert_every_leaf_named(observed, translated) do
    raw = MachineState.active_leaf_states(observed)

    assert MapSet.size(raw) == MapSet.size(translated),
           "#{MapSet.size(raw) - MapSet.size(translated)} active leaf state(s) have no id; " <>
             "the expectation #{inspect(Enum.sort(translated))} cannot name them"
  end

  # The four library calls, each a thin adapter over Statifier's own function.

  defp parse_document(xml) do
    case Statifier.compile(xml) do
      {:ok, machine} -> machine
      {:error, errors} -> flunk("Document did not compile:\n#{format_errors(errors)}")
    end
  end

  defp initialize(machine), do: Statifier.initialize(machine)

  # Only the "name" key is read. The corpus's event map can carry other keys,
  # but nothing can observe event data until the datamodel lands, so
  # translating them now would be a field with no reader.
  defp send_event(state_chart, %{"name" => name}) do
    case Statifier.send_event(state_chart, name) do
      {:ok, next, effects} ->
        {next, effects}

      {:error, :not_running} ->
        flunk("Sent #{inspect(name)} to a state chart that has terminated")
    end
  end

  defp active_leaf_states(state_chart), do: Statifier.active_leaf_states(state_chart)

  defp format_errors(errors), do: Enum.map_join(errors, "\n", & &1.message)
end
