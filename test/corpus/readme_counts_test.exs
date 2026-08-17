defmodule Corpus.ReadmeCountsTest do
  use ExUnit.Case, async: true

  # sabotage: n/a - asserts a property of generated files/docs, no lib/ behavior

  @readme_path "tools/corpus/README.md"

  # Native-case counts behind the 5 exclusion keys that remove one or more of
  # the 127 native SCION cases (everything but `w3c-ecma`, which excludes the
  # separate 189-case duplicate tree instead - see tools/corpus/README.md's
  # SCION filter section for the reconciliation this pins). Hand-maintained
  # because an excluded case is never emitted, so its count cannot be read
  # off disk the way an emitted count can; a key added, removed, or resized
  # here without a matching README edit fails the reconciliation test below.
  @native_exclusion_case_counts %{
    "script-src" => 4,
    "error" => 1,
    "assign-current-small-step/test0" => 1,
    "more-parallel/test10" => 1,
    "more-parallel/test10b" => 1
  }
  @native_scion_cases 127

  defp emitted_count(root) do
    root
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> length()
  end

  # Markdown line-wraps prose at ~80 columns, so a phrase this test looks for
  # can straddle a newline. Collapse all whitespace runs (including
  # newlines) to a single space before matching, so wrapping is invisible to
  # the assertion.
  defp readme do
    @readme_path
    |> File.read!()
    |> String.replace(~r/\s+/, " ")
  end

  describe "tools/corpus/README.md emitted-case counts" do
    # sabotage: n/a - pins the README's SCION emitted-case sentence against a
    # fresh count of test/scion_tests, no lib/ behavior
    test "SCION emitted count matches disk" do
      scion_emitted = emitted_count("test/scion_tests")

      assert readme() =~ "#{scion_emitted} of the 127 native SCION cases emit",
             "README's SCION emitted-case prose is stale (disk has #{scion_emitted} emitted)"
    end

    # sabotage: n/a - pins the README's W3C mandatory/optional/total sentence
    # against a fresh count of test/scxml_tests, no lib/ behavior
    test "W3C emitted counts (mandatory + optional) match disk" do
      mandatory = emitted_count("test/scxml_tests/mandatory")
      optional = emitted_count("test/scxml_tests/optional")
      total = mandatory + optional

      assert total == emitted_count("test/scxml_tests")

      assert readme() =~ "#{total} of those emit (#{mandatory} mandatory + #{optional} optional)",
             "README's W3C emitted-case prose is stale (disk has #{mandatory} mandatory + " <>
               "#{optional} optional = #{total})"
    end

    # sabotage: n/a - pins the README's mix test.regression/test.baseline
    # denominator sentence against a fresh count of both emitted trees, no
    # lib/ behavior
    test "regression-ratchet denominator sentence matches disk" do
      scion_emitted = emitted_count("test/scion_tests")
      w3c_emitted = emitted_count("test/scxml_tests")

      assert readme() =~
               "against these emitted counts (#{scion_emitted} SCION, #{w3c_emitted} W3C)",
             "README's regression-ratchet denominator sentence is stale " <>
               "(disk has #{scion_emitted} SCION, #{w3c_emitted} W3C)"
    end

    # sabotage: n/a - pins exclusions.exs's key set and the hand-maintained
    # per-key case counts against the 127-native-vs-emitted arithmetic, no
    # lib/ behavior
    test "SCION exclusions.exs keys reconcile the 127-native-vs-emitted gap" do
      exclusions_path = Path.join(["tools", "corpus", "scion", "exclusions.exs"])
      {exclusions, _bindings} = Code.eval_file(exclusions_path)

      native_exclusion_keys = Map.keys(exclusions) -- ["w3c-ecma"]

      assert MapSet.new(native_exclusion_keys) ==
               MapSet.new(Map.keys(@native_exclusion_case_counts)),
             "tools/corpus/scion/exclusions.exs keys changed - update " <>
               "@native_exclusion_case_counts here and the README's SCION filter " <>
               "reconciliation to match"

      scion_emitted = emitted_count("test/scion_tests")
      excluded_native_cases = @native_exclusion_case_counts |> Map.values() |> Enum.sum()

      assert scion_emitted + excluded_native_cases == @native_scion_cases,
             "emitted (#{scion_emitted}) + excluded native cases (#{excluded_native_cases}) " <>
               "no longer sums to #{@native_scion_cases} native SCION cases"
    end
  end
end
