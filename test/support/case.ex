defmodule Statifier.Case do
  @moduledoc """
  Test case template for the SCION and W3C conformance corpora.

  Every generated corpus test goes through `test_scxml/4` and nothing else, so
  this module is the entire coupling surface between the corpus and the library
  (ADR-0006). It needs exactly four things from `Statifier`:

  1. parse an SCXML document,
  2. build and initialize a state chart from it,
  3. send an event synchronously and get the next state chart back,
  4. read the active leaf-state set.

  Each of those lives in its own private helper below - `parse_document/1`,
  `initialize/1`, `send_event/2`, `active_leaf_states/1`. v2 has no engine yet,
  so today they flunk naming the call they are waiting on; landing the engine
  API these calls name (`Statifier.parse/1`, `Statifier.initialize/1`,
  `Interpreter.send_event/2`, `Configuration.active_leaf_states/1`) is a
  one-file change here, and the four-function contract stays a hard
  constraint on the library surface rather than something the corpus can widen.

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

  use ExUnit.CaseTemplate, async: true

  alias Statifier.FeatureDetector

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

    state_chart = xml |> parse_document() |> initialize()

    assert_configuration(state_chart, expected_initial_config)

    _final_state_chart =
      Enum.reduce(events, state_chart, fn {event_map, expected_states}, current_state_chart ->
        next_state_chart = send_event(current_state_chart, event_map)
        assert_configuration(next_state_chart, expected_states)
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

  defp assert_configuration(state_chart, expected_state_ids) do
    expected = MapSet.new(expected_state_ids)
    actual = active_leaf_states(state_chart)

    assert expected == actual,
           "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"
  end

  # The four library calls. Each is a single line once the engine lands; until
  # then it names what it is waiting on, so a corpus test that gets past the
  # feature gate says which part of the API is missing rather than raising
  # UndefinedFunctionError.

  defp parse_document(_xml), do: not_implemented("Statifier.parse/1")

  defp initialize(_document), do: not_implemented("Statifier.initialize/1")

  defp send_event(_state_chart, _event_map), do: not_implemented("Interpreter.send_event/2")

  defp active_leaf_states(_state_chart),
    do: not_implemented("Configuration.active_leaf_states/1")

  defp not_implemented(call) do
    flunk("""
    #{call} does not exist yet.

    Statifier.Case is waiting on the engine API these four calls name
    (`Statifier.parse/1`, `Statifier.initialize/1`, `Interpreter.send_event/2`,
    `Configuration.active_leaf_states/1`). Replace the matching helper in
    test/support/case.ex with the real call when it lands.
    """)
  end
end
