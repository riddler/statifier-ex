defmodule Corpus.GeneratedHeadersTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.Corpus.Emitter

  Code.require_file(Path.join([__DIR__, "..", "..", "tools/corpus/normalize.exs"]))

  # Every generated test module opens with the header its generator stamps
  # (tools/corpus/{scion,scxml_w3}/cases.exs): the corpus case it was written
  # from, the upstream document that case carries, and the licence notice
  # under conformance/LICENSES/ (ADR-0070). The modules are read from a fresh
  # glob of both trees and matched to the committed corpus by the case id the
  # header names; nothing here keeps a list of its own.

  @trees %{"scion" => "test/scion_tests", "w3c" => "test/scxml_tests"}

  defp modules(suite), do: (@trees[suite] <> "/**/*_test.exs") |> Path.wildcard() |> Enum.sort()

  defp cases(suite) do
    "conformance/corpus/#{suite}.json" |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")
  end

  # The leading `#` comment block as one line of prose, whitespace collapsed,
  # so where the generator wrapped a line is invisible to the assertions.
  defp header(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "#"))
    |> Enum.map_join(" ", &String.trim_leading(&1, "#"))
    |> squeeze()
  end

  defp squeeze(text), do: text |> String.split() |> Enum.join(" ")

  defp w3c_copyright do
    "conformance/LICENSES/BSD-3-Clause-W3C.txt"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "Copyright"))
  end

  # The case a header names, looked up in the committed corpus.
  defp named_case(header, suite, by_id) do
    case Regex.run(
           ~r/\AGenerated from conformance\/corpus\/#{suite}\.json, case (\S+), by /,
           header
         ) do
      [_match, id] -> Map.get(by_id, id)
      nil -> nil
    end
  end

  for suite <- ["scion", "w3c"] do
    # sabotage: dropping the upstream-document sentence from the generator's
    # header and running `mise run corpus:emit` -> red
    test "every #{suite} module's header names its corpus case, its upstream document and the licence notice" do
      suite = unquote(suite)
      by_id = Map.new(cases(suite), &{&1["id"], &1})
      paths = modules(suite)

      assert paths != [], "no generated #{suite} modules to check"

      for path <- paths do
        header = header(path)
        corpus_case = named_case(header, suite, by_id)

        assert corpus_case, "#{path}: its header names no #{suite} corpus case"

        assert Emitter.generated_path(corpus_case, ".") == path,
               "#{path}: header names another case"

        %{"document" => document, "notice" => notice} = corpus_case["upstream"]

        assert header =~
                 "tools/corpus/#{if suite == "w3c", do: "scxml_w3", else: "scion"}/cases.exs"

        assert header =~ "The document in this test is ", path
        assert header =~ " #{document} ", path
        assert header =~ "conformance/#{notice}", path
        assert header =~ corpus_case["upstream"]["license"], path
      end
    end
  end

  # sabotage: dropping the copyright line from tools/corpus/scxml_w3/cases.exs's
  # header and running `mise run corpus:emit` -> red
  test "every W3C module's header retains the W3C copyright notice from the licence file" do
    copyright = w3c_copyright()
    paths = modules("w3c")

    assert copyright =~ "W3C", "the licence file carries no copyright line"
    assert paths != [], "no generated W3C modules to check"

    for path <- paths, do: assert(header(path) =~ copyright, path)
  end

  # sabotage: dropping the modified paragraph from tools/corpus/scion/cases.exs's
  # header and running `mise run corpus:emit` -> red
  test "a SCION module carries its case's modification notice exactly when the corpus case does" do
    carrying =
      for %{"upstream" => %{"modified" => notice}} = corpus_case <- cases("scion") do
        path = Emitter.generated_path(corpus_case, ".")
        assert header(path) =~ squeeze(notice), path
        path
      end

    assert carrying != [], "no SCION case carries a modification notice, so nothing is checked"

    notices = for %{"upstream" => %{"modified" => notice}} <- cases("scion"), do: squeeze(notice)

    for path <- modules("scion"), path not in carrying, notice <- notices do
      refute header(path) =~ notice, path
    end
  end
end
