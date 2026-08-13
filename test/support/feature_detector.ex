defmodule Statifier.FeatureDetector do
  @moduledoc """
  Detects SCXML features used in documents so the test harness can fail
  precisely on unsupported features.

  This is harness code, not library surface: nothing in `lib/` may reference it.
  A test whose document uses an unsupported feature flunks with that feature
  named, so it can never masquerade as passing (see `docs/testing.md`, ADR-0006).

  Detection is regex-based over raw XML. v2 has no parsed document struct yet;
  when one lands, a `detect_features/1` clause for it is added alongside the
  string clause.

  The registry reflects what v2 actually supports today: the Phase 1 engine
  surface landed through st-wju.7 - basic/compound/parallel/final/history
  states, the initial attribute and `<initial>` element, event/eventless/
  targetless/internal/wildcard transitions, `<onentry>`/`<onexit>`,
  `<raise>`, `<log>`, and static `<donedata>`. Everything datamodel-flavored
  (`cond`, `<datamodel>`, `<assign>`, `<script>`, `<send>`, `<invoke>`, and so
  on) stays `:unsupported`. Each later phase flips more features to
  `:supported` as they land.
  """

  @doc """
  Detects features used in an SCXML document.

  Returns a `MapSet` of feature atoms.

  ## Examples

      iex> Statifier.FeatureDetector.detect_features("<scxml><state id='s1'/></scxml>")
      MapSet.new([:basic_states])
  """
  @spec detect_features(xml :: String.t()) :: MapSet.t(atom())
  def detect_features(xml) when is_binary(xml) do
    MapSet.new()
    |> detect_elements(xml)
    |> detect_attributes(xml)
  end

  @doc """
  Returns every known SCXML feature with its support status in v2.

  - `:supported` - fully implemented
  - `:partial` - partially implemented, allowed to run since simple cases may work
  - `:unsupported` - not yet implemented
  """
  @spec feature_registry() :: %{atom() => :supported | :unsupported | :partial}
  def feature_registry do
    %{
      # st-wju.1 / st-wju.6
      basic_states: :supported,
      # st-wju.4 (also covers the `initial` attribute - the detector has no
      # separate atom for it)
      compound_states: :supported,
      # st-wju.4
      parallel_states: :supported,
      # st-wju.4 / st-wju.6
      final_states: :supported,
      # st-wju.4
      initial_elements: :supported,
      # st-wju.4 (shallow and deep)
      history_states: :supported,
      # st-wju.3
      event_transitions: :supported,
      # st-wju.6
      eventless_transitions: :supported,
      conditional_transitions: :unsupported,
      # st-wju.3
      targetless_transitions: :supported,
      # st-wju.3
      internal_transitions: :supported,
      # st-wju.3 (Statifier.Interpreter.NameMatch implements spec 3.13's
      # trailing wildcard)
      wildcard_events: :supported,
      event_expressions: :unsupported,
      target_expressions: :unsupported,
      # st-af3.3
      datamodel: :supported,
      # st-af3.3
      data_elements: :supported,
      # st-af3.4
      assign_elements: :supported,
      script_elements: :unsupported,
      # st-wju.5
      onentry_actions: :supported,
      # st-wju.5
      onexit_actions: :supported,
      # st-af3.5
      if_elements: :supported,
      # st-af3.6
      foreach_elements: :supported,
      # st-wju.5
      log_elements: :supported,
      # st-wju.5
      raise_elements: :supported,
      send_elements: :unsupported,
      send_content_elements: :unsupported,
      send_param_elements: :unsupported,
      send_delay_expressions: :unsupported,
      send_idlocation: :unsupported,
      cancel_elements: :unsupported,
      invoke_elements: :unsupported,
      finalize_elements: :unsupported,
      # st-wju.6 (static donedata only)
      donedata_elements: :supported
    }
  end

  @doc """
  Checks that every detected feature is supported or partial.

  Returns `{:ok, detected_features}` when all are, otherwise
  `{:error, unsupported_features}`. Partial features are allowed through since
  they may work in simple cases. A feature absent from the registry counts as
  unsupported.
  """
  @spec validate_features(detected_features :: MapSet.t(atom())) ::
          {:ok, MapSet.t(atom())} | {:error, MapSet.t(atom())}
  def validate_features(detected_features) do
    registry = feature_registry()

    unsupported =
      detected_features
      |> Enum.reject(&(Map.get(registry, &1, :unsupported) in [:supported, :partial]))
      |> MapSet.new()

    if MapSet.size(unsupported) == 0 do
      {:ok, detected_features}
    else
      {:error, unsupported}
    end
  end

  @element_features [
    {~r/<state(\s|>|\/>)/, :basic_states},
    {~r/<parallel(\s|>|\/>)/, :parallel_states},
    {~r/<final(\s|>|\/>)/, :final_states},
    {~r/<initial(\s|>|\/>)/, :initial_elements},
    {~r/<history(\s|>|\/>)/, :history_states},
    {~r/<transition(\s|>|\/>)/, :event_transitions},
    {~r/<datamodel(\s|>|\/>)/, :datamodel},
    {~r/<data(\s|>|\/>)/, :data_elements},
    {~r/<script(\s|>|\/>)/, :script_elements},
    {~r/<assign(\s|>|\/>)/, :assign_elements},
    {~r/<if(\s|>|\/>)/, :if_elements},
    {~r/<onentry(\s|>|\/>)/, :onentry_actions},
    {~r/<onexit(\s|>|\/>)/, :onexit_actions},
    {~r/<send(\s|>|\/>)/, :send_elements},
    {~r/<log(\s|>|\/>)/, :log_elements},
    {~r/<raise(\s|>|\/>)/, :raise_elements},
    {~r/<foreach(\s|>|\/>)/, :foreach_elements},
    {~r/<invoke(\s|>|\/>)/, :invoke_elements},
    {~r/<finalize(\s|>|\/>)/, :finalize_elements},
    {~r/<cancel(\s|>|\/>)/, :cancel_elements},
    {~r/<content(\s|>|\/>)/, :send_content_elements},
    {~r/<param(\s|>|\/>)/, :send_param_elements},
    {~r/<donedata(\s|>|\/>)/, :donedata_elements}
  ]

  @attribute_features [
    {~r/\bcond\s*=/, :conditional_transitions},
    {~r/\bidlocation\s*=/, :send_idlocation},
    {~r/\beventexpr\s*=/, :event_expressions},
    {~r/\btargetexpr\s*=/, :target_expressions},
    {~r/\btype\s*=\s*["']internal["']/, :internal_transitions},
    {~r/\bevent\s*=\s*["']\*["']/, :wildcard_events},
    {~r/\bdelayexpr\s*=/, :send_delay_expressions},
    {~r/\bdelay\s*=/, :send_delay_expressions}
  ]

  defp detect_elements(features, xml), do: add_matches(features, xml, @element_features)

  defp detect_attributes(features, xml) do
    features
    |> add_matches(xml, @attribute_features)
    |> detect_compound_states(xml)
    |> detect_eventless_transitions(xml)
    |> detect_targetless_transitions(xml)
  end

  defp add_matches(features, xml, patterns) do
    Enum.reduce(patterns, features, fn {pattern, feature}, acc ->
      if Regex.match?(pattern, xml), do: MapSet.put(acc, feature), else: acc
    end)
  end

  defp detect_compound_states(features, xml) do
    if Regex.match?(~r/<state[^>]+\binitial\s*=/, xml) or
         Regex.match?(~r/<state[^>]*>.*<state/s, xml) do
      MapSet.put(features, :compound_states)
    else
      features
    end
  end

  defp detect_eventless_transitions(features, xml) do
    if Regex.match?(~r/<transition(?![^>]*\bevent\s*=)[^>]*>/, xml) do
      MapSet.put(features, :eventless_transitions)
    else
      features
    end
  end

  defp detect_targetless_transitions(features, xml) do
    if Regex.match?(~r/<transition(?![^>]*\btarget\s*=)[^>]*>/, xml) do
      MapSet.put(features, :targetless_transitions)
    else
      features
    end
  end
end
