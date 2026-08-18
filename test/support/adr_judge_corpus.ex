defmodule Mix.Statifier.AdrJudgeCorpus do
  @moduledoc """
  Shared manifest/fixture loader for the ADR judge corpus, used by the
  real-CLI corpus tests (`test/mix/statifier/adr_judge_corpus_test.exs`) and
  the caller-free shape test
  (`test/mix/statifier/adr_judge_corpus_shape_test.exs`) so the two agree on
  where the manifest and fixtures live and how a `source()` is built from a
  manifest row, rather than each re-deriving it.

  `test/support/` is already on the `:test` elixirc path (`mix.exs`) and is
  excluded from coverage (`docs/testing.md`), so this adds no coverage
  pressure.
  """

  alias Mix.Statifier.AdrJudge

  @fixture_dir "test/fixtures/adr_judge"
  @manifest_path Path.join(@fixture_dir, "manifest.exs")

  @doc "The directory every fixture file in the manifest is relative to."
  @spec fixture_dir() :: String.t()
  def fixture_dir, do: @fixture_dir

  @doc "The manifest file's own path, for error messages."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc """
  The corpus manifest: one map per fixture, with `:key` (a judged-ADR
  registry key), `:file` (relative to `fixture_dir/0`), `:expect`
  (`:violation` or `:clean`), `:tier` (`:blatant` or `:subtle`), and `:note`.
  A `:blatant` fixture is a deletion or omission the deterministic guards
  (`AdrGuard`, `GateGuard`) would also catch; a `:subtle` fixture preserves
  the shape of the change it fakes and breaks only its meaning.
  """
  @spec manifest() :: [map()]
  def manifest, do: @manifest_path |> Code.eval_file() |> elem(0)

  @doc """
  Builds an `AdrJudge.source()` for a single manifest row: the row's fixture
  diff, sliced into the one judged ADR its `:key` names, using that
  registry entry's own `scope` and `adr_path` rather than a value re-typed
  at the call site.
  """
  @spec source_for(entry :: map()) :: AdrJudge.source()
  def source_for(entry) do
    registry = Enum.find(AdrJudge.judged(), &(&1.key == entry.key))
    diff = File.read!(Path.join(@fixture_dir, entry.file))

    %{
      diff: diff,
      adrs: [
        %{
          key: registry.key,
          label: registry.label,
          focus: registry.focus,
          adr_text: File.read!(registry.adr_path),
          chunks: AdrJudge.scoped_chunks(diff, registry.scope)
        }
      ]
    }
  end
end
