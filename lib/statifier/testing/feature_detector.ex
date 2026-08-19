defmodule Statifier.Testing.FeatureDetector do
  @moduledoc """
  Detects SCXML features used in documents so the test harness can fail
  precisely on unsupported features.

  Test-side surface for chart authors, versioned with the engine: no module in
  `lib/` outside `Statifier.Testing.*` may reference anything inside it, so the
  engine never consults feature detection to decide behavior (ADR-0052,
  amending ADR-0006).
  A test whose document uses an unsupported feature flunks with that feature
  named, so it can never masquerade as passing (see `docs/testing.md`, ADR-0006).

  Detection is regex-based over raw XML. v2 has no parsed document struct yet;
  when one lands, a `detect_features/1` clause for it is added alongside the
  string clause.

  The registry reflects what v2 actually supports today:
  basic/compound/parallel/final/history states, the initial attribute and
  `<initial>` element, event/eventless/targetless/internal/wildcard
  transitions, `<onentry>`/`<onexit>`, `<raise>`, `<log>`, static
  `<donedata>`, `<datamodel>`/`<data>`, `<assign>`, `cond`-guarded
  transitions (including `<if>`/`<elseif>`/`<else>`), `<foreach>`, and
  `<script>` (`:partial` - see the registry entry), `<send>`/`<invoke>`/
  `<cancel>`/`<finalize>` and their attributes. `script_elements` is the only
  entry that is not `:supported`; see `feature_registry/0` for the
  authoritative, up-to-date list.
  """

  @doc """
  Detects features used in an SCXML document.

  Returns a `MapSet` of feature atoms.

  ## Examples

      iex> Statifier.Testing.FeatureDetector.detect_features("<scxml><state id='s1'/></scxml>")
      MapSet.new([:basic_states])
  """
  @spec detect_features(xml :: String.t()) :: MapSet.t(atom())
  def detect_features(xml) when is_binary(xml) do
    MapSet.new()
    |> detect_elements(xml)
    |> detect_send_children(xml)
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
      basic_states: :supported,
      # also covers the `initial` attribute - the detector has no
      # separate atom for it
      compound_states: :supported,
      parallel_states: :supported,
      final_states: :supported,
      initial_elements: :supported,
      # shallow and deep
      history_states: :supported,
      event_transitions: :supported,
      eventless_transitions: :supported,
      conditional_transitions: :supported,
      targetless_transitions: :supported,
      internal_transitions: :supported,
      # Statifier.Interpreter.NameMatch implements spec 3.13's
      # trailing wildcard
      wildcard_events: :supported,
      event_expressions: :supported,
      target_expressions: :supported,
      datamodel: :supported,
      data_elements: :supported,
      assign_elements: :supported,
      # :partial, not :supported: the element is implemented, but
      # bodies outside predicator's statement grammar (var, compound
      # assignment, object literals, typeof, function definitions) are kept
      # out of the corpus at generation time (tools/corpus/*/exclusions.exs),
      # not caught here at detection time.
      script_elements: :partial,
      onentry_actions: :supported,
      onexit_actions: :supported,
      if_elements: :supported,
      foreach_elements: :supported,
      log_elements: :supported,
      raise_elements: :supported,
      send_elements: :supported,
      send_content_elements: :supported,
      send_param_elements: :supported,
      send_delay_expressions: :supported,
      send_idlocation: :supported,
      cancel_elements: :supported,
      invoke_elements: :supported,
      finalize_elements: :supported,
      # static donedata only
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
    {~r/<donedata(\s|>|\/>)/, :donedata_elements}
  ]

  # <content> and <param> are legal under <send>, <invoke>, and <donedata>.
  # Only the <send> flavour is gated on send support - <donedata>'s children
  # landed separately - so these two run over a copy with the <donedata>
  # blocks removed. Every other pattern, <donedata> included, still sees the
  # untouched source.
  #
  # The two atoms keep their `send_`-prefixed names, which lump <invoke>'s
  # children in with <send>'s, even though `<invoke>` is not a `<send>`
  # child. The rename is declined: with send_elements and invoke_elements
  # both :supported, the attribution can no longer change any gate outcome,
  # and the atom names are emitted into every generated file's tag list, so
  # renaming them would need a corpus regeneration for no behavioral gain.
  @send_child_features [
    {~r/<content(\s|>|\/>)/, :send_content_elements},
    {~r/<param(\s|>|\/>)/, :send_param_elements}
  ]

  # <donedata> holds only <param> and <content>, so it never nests and the
  # non-greedy run to the first close tag is exact. The lookbehind keeps a
  # self-closing <donedata/> - which has no children to strip - from opening a
  # span that swallows everything up to some later </donedata>.
  @donedata_block ~r{<donedata\b[^>]*(?<!/)>.*?</donedata\s*>}s

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

  defp detect_send_children(features, xml) do
    add_matches(features, String.replace(xml, @donedata_block, ""), @send_child_features)
  end

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
