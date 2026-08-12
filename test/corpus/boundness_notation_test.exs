defmodule Corpus.BoundnessNotationTest do
  use ExUnit.Case, async: true

  # sabotage: n/a - asserts a property of generated files, no lib/ behavior

  @scxml_tests_root "test/scxml_tests"
  @sentinel "_statifier_unbound"
  @non_strict_undefined ~r/(?<![!=])==\s*undefined/

  defp corpus_files do
    Path.wildcard(Path.join([@scxml_tests_root, "**", "*_test.exs"]))
  end

  defp lines_matching(path, matcher) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> matcher.(line) end)
    |> Enum.map(fn {line, line_no} -> "#{path}:#{line_no}: #{String.trim(line)}" end)
  end

  describe "boundness notation" do
    # sabotage: revert test528's cond to _statifier_unbound -> red
    test "no emitted file references the retired _statifier_unbound sentinel" do
      offenders =
        for path <- corpus_files(),
            offense <- lines_matching(path, &String.contains?(&1, @sentinel)) do
          offense
        end

      assert offenders == [],
             "found retired sentinel #{@sentinel} in the emitted corpus " <>
               "(boundness must be spelled === undefined / !== undefined):\n" <>
               Enum.join(offenders, "\n")
    end

    # sabotage: revert test528's cond to _event.data == undefined -> red
    test "no emitted file compares against undefined with non-strict ==" do
      offenders =
        for path <- corpus_files(),
            offense <- lines_matching(path, &Regex.match?(@non_strict_undefined, &1)) do
          offense
        end

      assert offenders == [],
             "found non-strict `== undefined` in the emitted corpus " <>
               "(== undefined propagates :undefined instead of testing boundness; " <>
               "use === undefined / !== undefined):\n" <>
               Enum.join(offenders, "\n")
    end

    # sabotage: n/a - non-vacuity guard over generated corpus, no lib/ behavior
    test "the strict undefined literal is used somewhere (non-vacuity)" do
      hits =
        for path <- corpus_files(),
            String.contains?(File.read!(path), "=== undefined") or
              String.contains?(File.read!(path), "!== undefined") do
          path
        end

      assert hits != [],
             "expected at least one emitted file to compare against the undefined literal " <>
               "with a strict operator; found none under #{@scxml_tests_root}"
    end
  end
end
