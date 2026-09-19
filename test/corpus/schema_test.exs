defmodule Corpus.SchemaTest do
  use ExUnit.Case, async: true

  import Statifier.Testing.Case, only: [test_scxml: 4]

  alias Statifier.CorpusSchemaChecker, as: Checker
  alias Statifier.Testing.FeatureDetector

  # The corpus schemas under conformance/schema/ (ADR-0070), proved with a
  # hand-written checker (test/support/corpus_schema_checker.ex) against the
  # fixtures in test/fixtures/corpus_schema/. Every accepting fixture is
  # checked as written; every refusal is that fixture with one named change,
  # and asserts the error lands where the change was made, so a refusal
  # cannot pass for an unrelated reason.

  @schema_dir "conformance/schema"
  @fixture_dir "test/fixtures/corpus_schema"
  @schemas ~w(case.json corpus.json manifest.json registry.json exclusions.json)
  @draft "https://json-schema.org/draft/2020-12/schema"

  defp schema(name), do: Checker.load(@schema_dir, name)
  defp fixture(name), do: Checker.load(@fixture_dir, name)

  defp errors(schema_name, instance),
    do: Checker.errors(schema(schema_name), instance, @schema_dir)

  defp pointers(schema_name, instance),
    do: schema_name |> errors(instance) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  describe "the schema files" do
    # sabotage: n/a - asserts the committed schema files, no lib/ behavior;
    # deleting conformance/schema/exclusions.json -> red (File.read! raises)
    test "every schema is JSON, declares draft 2020-12 and its own $id" do
      for name <- @schemas do
        assert %{"$schema" => @draft, "$id" => id} = schema(name)
        assert id == "https://github.com/riddler/statifier-ex/conformance/schema/" <> name
      end
    end

    # sabotage: n/a - asserts the committed schema files, no lib/ behavior;
    # adding "maxItems": 5 to case.json's steps -> red, naming /properties/steps
    test "every keyword every schema uses is one the checker implements" do
      for name <- @schemas do
        assert Checker.unsupported_keywords(schema(name)) == [],
               "#{name} uses a keyword the checker ignores"
      end
    end

    # sabotage: n/a - asserts the committed schema files, no lib/ behavior;
    # corpus.json's items pointing at "cases.json" -> red
    test "every $ref names a schema file in the directory" do
      refs = Enum.flat_map(@schemas, &Checker.refs(schema(&1)))

      assert refs != [], "corpus.json's cases are checked through case.json by $ref"
      assert Enum.all?(refs, &(&1 in @schemas)), "unresolved $ref in #{inspect(refs)}"
    end

    # sabotage: n/a - asserts the committed README, no lib/ behavior;
    # deleting its never-hand-edited sentence -> red
    test "the conformance README says the generated files are never hand-edited" do
      readme = File.read!("conformance/README.md")

      for file <- ~w(corpus/ manifest.json registry.json exclusions.json) do
        assert readme =~ file
      end

      assert readme =~ "never edited by hand"
    end
  end

  describe "case.json" do
    # sabotage: dropping "statifier" from case.json's suite enum -> red on
    # case-statifier.json at /suite
    test "accepts one case per suite" do
      for name <- ~w(case-scion.json case-w3c.json case-statifier.json) do
        assert errors("case.json", fixture(name)) == [], "#{name} refused"
      end
    end

    # sabotage: adding "ecma" to case.json's suite enum -> red
    test "refuses a case with an unknown suite" do
      assert "/suite" in pointers("case.json", %{fixture("case-w3c.json") | "suite" => "ecma"})
    end

    # sabotage: deleting "upstream" from the w3c branch's required list -> red
    test "refuses a scion or w3c case with no upstream" do
      for name <- ~w(case-scion.json case-w3c.json) do
        case_without = Map.delete(fixture(name), "upstream")
        assert {"", "missing required upstream"} in errors("case.json", case_without)
      end
    end

    # sabotage: deleting the statifier branch's "not" -> red
    test "refuses a statifier case that carries upstream" do
      upstream = fixture("case-scion.json")["upstream"]
      with_upstream = Map.put(fixture("case-statifier.json"), "upstream", upstream)

      assert "" in pointers("case.json", with_upstream)
    end

    # sabotage: deleting the scion branch's "not" -> red
    test "refuses host on a scion or w3c case" do
      host = fixture("case-statifier.json")["host"]

      for name <- ~w(case-scion.json case-w3c.json) do
        assert "" in pointers("case.json", Map.put(fixture(name), "host", host))
      end
    end

    # sabotage: host's send_types items losing "type": "string" -> red
    test "host admits only its two reserved members, send_types as strings" do
      statifier = fixture("case-statifier.json")

      assert "/host/send_types/0" in pointers(
               "case.json",
               put_in(statifier, ["host", "send_types"], [1])
             )

      assert "/host/routes" in pointers("case.json", put_in(statifier, ["host", "routes"], []))
      assert errors("case.json", Map.put(statifier, "host", %{})) == []
    end

    # sabotage: the w3c branch's conformance enum admitting null -> red
    test "a w3c case names its conformance class and the others carry null" do
      assert "/conformance" in pointers("case.json", %{
               fixture("case-w3c.json")
               | "conformance" => nil
             })

      assert "/conformance" in pointers("case.json", %{
               fixture("case-scion.json")
               | "conformance" => "mandatory"
             })
    end

    # sabotage: the scion branch's license const changed to BSD-3-Clause-W3C -> red
    test "each upstream suite carries its own licence" do
      w3c = fixture("case-w3c.json")
      scion = fixture("case-scion.json")

      assert "/upstream/license" in pointers(
               "case.json",
               put_in(w3c, ["upstream", "license"], "Apache-2.0")
             )

      assert "/upstream/license" in pointers(
               "case.json",
               put_in(scion, ["upstream", "license"], "BSD-3-Clause-W3C")
             )
    end

    # sabotage: the w3c branch's id pattern "^w3c/" deleted -> red
    test "a case id begins with its suite" do
      assert "/id" in pointers("case.json", %{fixture("case-w3c.json") | "id" => "scion/test286"})
    end

    # sabotage: the step's event losing "additionalProperties": false -> red
    test "a step's event carries a name and at most data" do
      [step | rest] = fixture("case-scion.json")["steps"]
      scion = fixture("case-scion.json")

      assert "/steps/0/event/after" in pointers("case.json", %{
               scion
               | "steps" => [put_in(step, ["event", "after"], 10) | rest]
             })

      assert "/steps/0/event" in pointers("case.json", %{
               scion
               | "steps" => [%{step | "event" => %{}} | rest]
             })
    end
  end

  describe "the case fields drive the generated-module harness" do
    # sabotage: Statifier.Testing.FeatureDetector.detect_features/1 dropping
    # :final_states -> red on case-w3c.json and case-statifier.json
    test "each fixture's required_features is what the feature detector finds in its source" do
      for name <- ~w(case-scion.json case-w3c.json case-statifier.json) do
        %{"source" => source, "required_features" => features} = fixture(name)

        detected =
          source
          |> FeatureDetector.detect_features()
          |> Enum.map(&Atom.to_string/1)
          |> Enum.sort()

        assert features == detected, "#{name}: #{inspect(features)} != #{inspect(detected)}"
      end
    end

    # sabotage: case-scion.json's second step expecting ["b"] -> red
    test "the scion and w3c fixtures pass test_scxml/4 as the generated modules call it" do
      for name <- ~w(case-scion.json case-w3c.json) do
        %{"source" => source, "description" => description} = case_map = fixture(name)
        steps = Enum.map(case_map["steps"], &{&1["event"], &1["configuration"]})

        assert test_scxml(source, description, case_map["initial_configuration"], steps) == :ok
      end
    end
  end

  describe "corpus.json" do
    # sabotage: corpus.json's cases minItems deleted -> red on the empty file
    test "accepts a suite file and refuses one with no cases" do
      corpus = fixture("corpus.json")

      assert errors("corpus.json", corpus) == []
      assert "/cases" in pointers("corpus.json", %{corpus | "cases" => []})
    end

    # sabotage: corpus.json's items losing its $ref -> red
    test "checks every case through case.json" do
      corpus = fixture("corpus.json")
      [w3c_case] = corpus["cases"]

      assert "/cases/0/suite" in pointers("corpus.json", %{
               corpus
               | "cases" => [%{w3c_case | "suite" => "ecma"}]
             })
    end
  end

  describe "manifest.json" do
    # sabotage: manifest.json's case_count minimum lowered to 0 -> red
    test "accepts a manifest and refuses a suite with no cases" do
      manifest = fixture("manifest.json")
      [scion | rest] = manifest["suites"]

      assert errors("manifest.json", manifest) == []

      assert "/suites/0/case_count" in pointers("manifest.json", %{
               manifest
               | "suites" => [%{scion | "case_count" => 0} | rest]
             })
    end
  end

  describe "registry.json" do
    # sabotage: "w3c" added to registry.json's claims enum -> red
    test "accepts a registry and refuses a claim outside the four claim names" do
      registry = fixture("registry.json")

      assert errors("registry.json", registry) == []
      assert "/claims/0" in pointers("registry.json", %{registry | "claims" => ["w3c"]})
    end

    # sabotage: registry.json's entries minItems deleted -> red
    test "every entry carries its case's suite and an empty registry is refused" do
      registry = fixture("registry.json")
      [entry | rest] = registry["entries"]

      assert "/entries/0" in pointers("registry.json", %{
               registry
               | "entries" => [Map.delete(entry, "suite") | rest]
             })

      assert "/entries" in pointers("registry.json", %{registry | "entries" => []})
    end
  end

  describe "exclusions.json" do
    # sabotage: exclusions.json's reason pattern admitting a leading colon -> red
    test "accepts an exclusions file and refuses a reason that is not a bare atom name" do
      exclusions = fixture("exclusions.json")
      [scion | rest] = exclusions["exclusions"]

      assert errors("exclusions.json", exclusions) == []

      assert "/exclusions/0/reason" in pointers("exclusions.json", %{
               exclusions
               | "exclusions" => [%{scion | "reason" => ":needs_external_fetch"} | rest]
             })
    end

    # sabotage: the adr property deleted from exclusions.json (additionalProperties
    # then refuses it) -> red on the accepting half; its "minimum": 1 deleted -> red
    # on the zero
    test "an entry may carry the number of the record its prose cites, as a positive integer" do
      exclusions = fixture("exclusions.json")
      [scion | rest] = exclusions["exclusions"]

      assert scion["adr"] == 26
      assert errors("exclusions.json", exclusions) == []

      assert errors("exclusions.json", %{
               exclusions
               | "exclusions" => [Map.delete(scion, "adr") | rest]
             }) ==
               []

      for bad <- ["ADR-0026", 0, 26.5] do
        assert "/exclusions/0/adr" in pointers("exclusions.json", %{
                 exclusions
                 | "exclusions" => [%{scion | "adr" => bad} | rest]
               })
      end
    end

    # sabotage: the key pattern admitting a second slash -> red
    test "a key is a W3C id, a SCION directory, or a SCION directory/name pair" do
      exclusions = fixture("exclusions.json")
      [scion | rest] = exclusions["exclusions"]

      assert "/exclusions/0/key" in pointers("exclusions.json", %{
               exclusions
               | "exclusions" => [%{scion | "key" => "script-src/a/b"} | rest]
             })
    end
  end

  describe "the checker" do
    # sabotage: n/a - harness plumbing; the checker is test support, and its
    # own keyword coverage is what the schema tests above exercise. Deleting
    # the checker's final raising keyword/6 clause -> red here
    test "raises on a keyword it does not implement instead of ignoring it" do
      assert_raise ArgumentError, ~r/maxItems/, fn ->
        Checker.errors(%{"maxItems" => 1}, [1, 2], @schema_dir)
      end

      assert Checker.unsupported_keywords(%{"additionalProperties" => %{}, "$ref" => "#/x"}) == [
               {"", "$ref"},
               {"", "additionalProperties"}
             ]
    end
  end
end
