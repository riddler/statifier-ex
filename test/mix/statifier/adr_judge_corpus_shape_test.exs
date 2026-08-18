defmodule Mix.Statifier.AdrJudgeCorpusShapeTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.{AdrJudge, AdrJudgeCorpus}

  # Caller-free: no opts[:caller] is ever passed to AdrJudge.analyze/2 here,
  # so this test runs in the ordinary suite (unlike
  # adr_judge_corpus_test.exs) and keeps the corpus honest between the rare
  # hand-runs of the real-CLI suite.
  @manifest AdrJudgeCorpus.manifest()

  # sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
  test "every manifest row's file exists under test/fixtures/adr_judge/" do
    for entry <- @manifest do
      path = Path.join(AdrJudgeCorpus.fixture_dir(), entry.file)
      assert File.exists?(path), "missing fixture: #{path}"
    end
  end

  # sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
  test "every manifest row's key is a real registry key" do
    registry_keys = MapSet.new(AdrJudge.judged(), & &1.key)

    for entry <- @manifest do
      assert entry.key in registry_keys, "#{entry.key} is not a registered judged ADR"
    end
  end

  # sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
  test "every registry entry has at least one violation and one clean fixture" do
    by_key = Enum.group_by(@manifest, & &1.key)

    for registry_entry <- AdrJudge.judged() do
      rows = Map.get(by_key, registry_entry.key, [])

      assert Enum.any?(rows, &(&1.expect == :violation)),
             "#{registry_entry.key} has no :violation fixture"

      assert Enum.any?(rows, &(&1.expect == :clean)),
             "#{registry_entry.key} has no :clean fixture"
    end
  end

  # sabotage: have in_scope?/2 ignore scope.prefix -> red (the 0015 fixture
  #           would read as in ADR-0012's lib/statifier/ scope too)
  test "every fixture's diff lands in its own scope, and not in a differing one" do
    for entry <- @manifest do
      registry = Enum.find(AdrJudge.judged(), &(&1.key == entry.key))
      diff = File.read!(Path.join(AdrJudgeCorpus.fixture_dir(), entry.file))

      assert AdrJudge.scoped_chunks(diff, registry.scope) != [],
             "#{entry.file} produced no chunks in #{entry.key}'s own scope"

      other_scope =
        AdrJudge.judged()
        |> Enum.map(& &1.scope)
        |> Enum.find(&(&1 != registry.scope))

      refute is_nil(other_scope),
             "no differing scope registered to compare #{entry.file} against"

      assert AdrJudge.scoped_chunks(diff, other_scope) == [],
             "#{entry.file} unexpectedly landed in a differing scope too"
    end
  end

  # sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
  test "no fixture contains the literal @tag :skip" do
    AdrJudgeCorpus.fixture_dir()
    |> Path.join("*.diff")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      refute File.read!(path) =~ "@tag :skip", "#{path} contains the literal @tag :skip"
    end)
  end
end
