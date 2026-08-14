defmodule Statifier.Case do
  @moduledoc """
  Test case template for the SCION and W3C conformance corpora.

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
    found, restores that effect's `configuration` (added to `Effect.Done` in
    st-k8d Phase 1) onto the `%MachineState{}` before reading leaves off it -
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
  (`Statifier.FeatureDetector`) - they never skip, so an unimplemented feature
  can never masquerade as a passing test. Since the registry currently marks
  everything `:unsupported`, that is where essentially every corpus test stops.
  Both suites are excluded by default (`:scion`, `:scxml_w3`), so `mix test`
  stays green while the ratchet starts at zero.

  v1's `StateMachine` and logging helpers are deliberately not ported: the
  subsystems they drove do not exist in v2, and reintroducing them here would
  grow the coupling surface this module exists to hold flat.
  """

  use ExUnit.CaseTemplate

  alias Statifier.FeatureDetector
  alias Statifier.MachineState

  using do
    quote do
      import unquote(__MODULE__)
    end
  end

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
    validate_features!(xml, description)

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

  defp validate_features!(xml, description) do
    detected = FeatureDetector.detect_features(xml)

    case FeatureDetector.validate_features(detected) do
      {:ok, _supported} ->
        :ok

      {:error, unsupported} ->
        flunk("""
        Test depends on unsupported SCXML features: #{format_features(unsupported)}

        This test cannot pass until these features are implemented in Statifier.
        Detected features: #{format_features(detected)}

        For which features are supported, see Statifier.FeatureDetector.feature_registry/0
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
  # core :done effect instead (Effect.Done.configuration, st-k8d Phase 1).
  # Restoring it onto the MachineState keeps the index-to-id translation
  # inside Statifier.active_leaf_states/1, where ADR-0005 puts it, rather
  # than reimplementing that translation here.
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
  # but nothing can observe event data until the datamodel lands (st-af3), so
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
