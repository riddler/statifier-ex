defmodule Mix.Statifier.Corpus.JsonTest do
  use ExUnit.Case, async: true

  doctest Mix.Statifier.Corpus.Json

  alias Mix.Statifier.Corpus.Json

  describe "the encodings" do
    # sabotage: ordered/1 sorting keys alphabetically -> red
    test "write a case's keys in the schema's order, not alphabetically" do
      corpus_case = %{
        "upstream" => %{"notice" => "n", "document" => "d", "license" => "l"},
        "steps" => [%{"configuration" => ["b"], "event" => %{"name" => "t"}}],
        "id" => "scion/a/b",
        "suite" => "scion"
      }

      assert Json.compact(corpus_case) ==
               ~s|{"id":"scion/a/b","suite":"scion","steps":[{"event":{"name":"t"},"configuration":["b"]}],| <>
                 ~s|"upstream":{"document":"d","license":"l","notice":"n"}}|
    end

    # sabotage: `unreachable` and `undeclared` deleted from @key_order ->
    # red (the two then sort alphabetically, `undeclared` first)
    test "write a host's accepts keys in the schema's order" do
      host = %{
        "expect_accepts" => %{"undeclared" => ["loan.due"], "unreachable" => []},
        "declared_events" => ["loan.renew"],
        "expect_sends" => [],
        "send_types" => ["library:timer"]
      }

      assert Json.compact(host) ==
               ~s|{"send_types":["library:timer"],"expect_sends":[],"declared_events":["loan.renew"],| <>
                 ~s|"expect_accepts":{"unreachable":[],"undeclared":["loan.due"]}}|
    end

    # sabotage: corpus_file/2 joining the cases with "," on one line -> red
    test "a corpus file holds one compact case per line and decodes to its suite and cases" do
      cases = [%{"id" => "w3c/test1", "steps" => []}, %{"id" => "w3c/test2", "steps" => []}]
      content = Json.corpus_file("w3c", cases)

      assert content ==
               ~s|{\n  "suite": "w3c",\n  "cases": [\n    {"id":"w3c/test1","steps":[]},\n| <>
                 ~s|    {"id":"w3c/test2","steps":[]}\n  ]\n}\n|

      assert JSON.decode!(content) == %{"suite" => "w3c", "cases" => cases}
    end

    # sabotage: ordered/1 ranking an unknown key before the known ones -> red
    test "an unknown key follows the known ones, sorted, and null stays null" do
      assert Json.compact(%{"zeta" => 1, "alpha" => nil, "id" => "x"}) ==
               ~s|{"id":"x","alpha":null,"zeta":1}|
    end
  end
end
