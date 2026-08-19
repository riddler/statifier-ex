defmodule Statifier.FeatureDetector do
  @moduledoc """
  Compatibility shim: the real module is `Statifier.Testing.FeatureDetector`,
  in `lib/`. This name is kept so the 281 generated corpus files and the
  `tools/corpus` generators need no regeneration (ADR-0053 decision 5).
  """

  alias Statifier.Testing.FeatureDetector

  @spec detect_features(xml :: String.t()) :: MapSet.t(atom())
  defdelegate detect_features(xml), to: FeatureDetector

  @spec feature_registry() :: %{atom() => :supported | :unsupported | :partial}
  defdelegate feature_registry(), to: FeatureDetector

  @spec validate_features(detected_features :: MapSet.t(atom())) ::
          {:ok, MapSet.t(atom())} | {:error, MapSet.t(atom())}
  defdelegate validate_features(detected_features), to: FeatureDetector
end
