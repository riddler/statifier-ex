defmodule Corpus.EmittedPathsTest do
  use ExUnit.Case, async: true

  # sabotage: n/a - asserts a property of generated files, no lib/ behavior

  @corpus_roots ["test/scion_tests", "test/scxml_tests"]
  @segment_pattern ~r/\A[a-z0-9_]+\z/

  defp corpus_files do
    for root <- @corpus_roots,
        path <- Path.wildcard(Path.join([root, "**", "*_test.exs"])) do
      path
    end
  end

  defp segments(path) do
    path
    |> String.replace_suffix("_test.exs", "")
    |> Path.split()
  end

  describe "emitted path shape" do
    test "every path segment matches the identifier/1 output shape" do
      offenders =
        for path <- corpus_files(),
            segment <- segments(path),
            not Regex.match?(@segment_pattern, segment) do
          {path, segment}
        end

      assert offenders == [],
             "path segments that Cases.Normalize.identifier/1 would not produce: #{inspect(offenders)}"
    end

    test "every defmodule name across the corpus is unique" do
      modules =
        for path <- corpus_files(),
            line <- File.read!(path) |> String.split("\n"),
            [_full, name] <- Regex.run(~r/\Adefmodule\s+(\S+)\s+do\z/, line) || [] do
          {name, path}
        end

      duplicates =
        modules
        |> Enum.group_by(fn {name, _path} -> name end)
        |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)

      assert duplicates == [],
             "duplicate defmodule names across the corpus: #{inspect(duplicates)}"
    end
  end
end
