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
    test "host admits only its reserved members, send_types as strings" do
      statifier = fixture("case-statifier.json")

      assert "/host/send_types/0" in pointers(
               "case.json",
               put_in(statifier, ["host", "send_types"], [1])
             )

      assert "/host/routes" in pointers("case.json", put_in(statifier, ["host", "routes"], []))
      assert errors("case.json", Map.put(statifier, "host", %{})) == []
    end

    # sabotage: send_types' items losing their "not" -> red on "scxml"
    test "host's send_types refuses a built-in spelling" do
      statifier = fixture("case-statifier.json")

      for built_in <- ["scxml", "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"] do
        assert "/host/send_types/0" in pointers(
                 "case.json",
                 put_in(statifier, ["host", "send_types"], [built_in])
               )
      end
    end

    # sabotage: the expect_sends item's "additionalProperties": false removed
    # -> red on the extra key; its "required" losing "target" -> red on the
    # missing target
    test "an expect_sends item is type, target and event, with optional delay_ms and send_id" do
      statifier = fixture("case-statifier.json")
      [item] = statifier["host"]["expect_sends"]
      with_item = &put_in(statifier, ["host", "expect_sends"], [&1])

      full =
        Map.merge(item, %{
          "event" => %{"name" => "reminder", "data" => %{"impression_id" => "imp-1"}},
          "delay_ms" => 5000,
          "send_id" => "reminder"
        })

      assert errors("case.json", with_item.(full)) == []
      assert errors("case.json", put_in(statifier, ["host", "expect_sends"], [])) == []

      assert "/host/expect_sends/0/event" in pointers(
               "case.json",
               with_item.(Map.put(item, "event", "impression.joined"))
             )

      assert "/host/expect_sends/0" in pointers(
               "case.json",
               with_item.(Map.delete(item, "target"))
             )

      assert "/host/expect_sends/0/ordinal" in pointers(
               "case.json",
               with_item.(Map.put(item, "ordinal", 1))
             )

      assert "/host/expect_sends/0/delay_ms" in pointers(
               "case.json",
               with_item.(Map.put(item, "delay_ms", -1))
             )

      assert "/host/expect_sends/0/event/sendid" in pointers(
               "case.json",
               with_item.(put_in(item, ["event", "sendid"], "x"))
             )
    end

    # sabotage: the expect_sends item's outcome property deleted from
    # case.json (additionalProperties then refuses it) -> red on the
    # fixture at /host/expect_sends/0/outcome
    test "an expect_sends item may carry an outcome, fail or cancelled" do
      outcome = fixture("case-statifier-outcome.json")

      assert [%{"outcome" => "fail"}, %{"outcome" => "cancelled"}] =
               outcome["host"]["expect_sends"]

      assert errors("case.json", outcome) == []
    end

    # sabotage: the outcome's enum gaining "delivered" -> red on the first
    # refusal
    test "an expect_sends item refuses any other outcome" do
      outcome = fixture("case-statifier-outcome.json")

      for other <- ["delivered", 1] do
        assert "/host/expect_sends/0/outcome" in pointers(
                 "case.json",
                 put_in(outcome, ["host", "expect_sends", Access.at(0), "outcome"], other)
               )
      end
    end

    # sabotage: host's declared_events property deleted from case.json
    # (additionalProperties then refuses it) -> red on the accepting half
    test "a statifier case's host may carry declared_events with expect_accepts" do
      accepts = fixture("case-statifier-accepts.json")

      assert %{"declared_events" => [_first | _rest], "expect_accepts" => %{}} = accepts["host"]
      assert errors("case.json", accepts) == []
      assert errors("case.json", put_in(accepts, ["host", "declared_events"], [])) == []
    end

    # sabotage: the host's first allOf branch (declared_events requires
    # expect_accepts) deleted -> red on the first half; the second deleted ->
    # red on the second
    test "declared_events and expect_accepts are present together or not at all" do
      accepts = fixture("case-statifier-accepts.json")
      {_expected, without_expected} = pop_in(accepts, ["host", "expect_accepts"])
      {_declared, without_declared} = pop_in(accepts, ["host", "declared_events"])

      assert {"/host", "missing required expect_accepts"} in errors("case.json", without_expected)

      assert {"/host", "missing required declared_events"} in errors(
               "case.json",
               without_declared
             )

      neither =
        accepts
        |> update_in(["host"], &Map.drop(&1, ["declared_events", "expect_accepts"]))

      assert errors("case.json", neither) == []
    end

    # sabotage: expect_accepts' "additionalProperties": false removed -> red
    # on the extra key; its "required" losing "undeclared" -> red on the
    # missing list; declared_events' items losing "type": "string" -> red on
    # the number; declared_events' "uniqueItems" deleted -> red on the
    # repeated name
    test "expect_accepts is exactly unreachable and undeclared, and each declared name a string" do
      accepts = fixture("case-statifier-accepts.json")

      assert "/host/expect_accepts/unexpected" in pointers(
               "case.json",
               put_in(accepts, ["host", "expect_accepts", "unexpected"], [])
             )

      {_undeclared, without_undeclared} =
        pop_in(accepts, ["host", "expect_accepts", "undeclared"])

      assert "/host/expect_accepts" in pointers("case.json", without_undeclared)

      assert "/host/declared_events/0" in pointers(
               "case.json",
               put_in(accepts, ["host", "declared_events"], [1])
             )

      assert "/host/declared_events" in pointers(
               "case.json",
               put_in(accepts, ["host", "declared_events"], ["loan.renew", "loan.renew"])
             )
    end

    # sabotage: host's expect_diff property deleted from case.json -> red
    test "a statifier case's host may carry a diff pair with mapping and expect_compatible_at" do
      diff = fixture("case-statifier-diff.json")

      assert %{"to_source" => _to_source, "mapping" => %{}, "expect_diff" => %{}} = diff["host"]
      assert is_boolean(diff["host"]["expect_compatible_at"])
      assert errors("case.json", diff) == []
    end

    # sabotage: each of the host's four new allOf branches deleted in turn ->
    # red on the half it guarded
    test "to_source and expect_diff are present together, and mapping and expect_compatible_at need them" do
      diff = fixture("case-statifier-diff.json")
      {_expected, without_expected} = pop_in(diff, ["host", "expect_diff"])

      without_to_source =
        update_in(diff, ["host"], &Map.drop(&1, ["to_source", "mapping", "expect_compatible_at"]))

      assert {"/host", "missing required expect_diff"} in errors("case.json", without_expected)
      assert {"/host", "missing required to_source"} in errors("case.json", without_to_source)

      bare = update_in(diff, ["host"], &Map.drop(&1, ["to_source", "expect_diff"]))
      assert {"/host", "missing required to_source"} in errors("case.json", bare)

      only_mapping = update_in(bare, ["host"], &Map.delete(&1, "expect_compatible_at"))
      only_predicate = update_in(bare, ["host"], &Map.delete(&1, "mapping"))
      assert {"/host", "missing required to_source"} in errors("case.json", only_mapping)
      assert {"/host", "missing required to_source"} in errors("case.json", only_predicate)

      neither = update_in(bare, ["host"], &Map.drop(&1, ["mapping", "expect_compatible_at"]))
      assert errors("case.json", neither) == []
    end

    # sabotage: expect_diff's class enum widened to any string -> red on
    # the unknown class; its "required" losing "reasons" -> red on the
    # missing list; expect_compatible_at's type deleted -> red on the string
    test "expect_diff is a class and its reasons, and expect_compatible_at a boolean" do
      diff = fixture("case-statifier-diff.json")

      assert "/host/expect_diff/class" in pointers(
               "case.json",
               put_in(diff, ["host", "expect_diff", "class"], "renamed")
             )

      {_reasons, without_reasons} = pop_in(diff, ["host", "expect_diff", "reasons"])
      assert "/host/expect_diff" in pointers("case.json", without_reasons)

      assert "/host/expect_compatible_at" in pointers(
               "case.json",
               put_in(diff, ["host", "expect_compatible_at"], "false")
             )
    end

    # sabotage: the state_mapped branch of the reason allOf deleted -> red on
    # the missing to_state; the state_added branch's "t_index": false
    # deleted -> red on the transition member; the reason
    # object's "additionalProperties": false removed -> red on the extra key
    test "each diff reason carries exactly the members its reason names" do
      diff = fixture("case-statifier-diff.json")
      reason_at = ["host", "expect_diff", "reasons"]

      with_reasons = fn reasons -> put_in(diff, reason_at, reasons) end

      assert errors(
               "case.json",
               with_reasons.([
                 %{"reason" => "state_nameless", "index" => 2},
                 %{
                   "reason" => "state_changed",
                   "state" => "idle",
                   "fields" => ["kind", "parent"]
                 },
                 %{"reason" => "transition_removed", "state" => "idle", "t_index" => 1},
                 %{"reason" => "event_added", "descriptor" => "copy.available"},
                 %{"reason" => "data_removed", "data_id" => "pending"},
                 %{"reason" => "mapping_unused", "state" => "idle"}
               ])
             ) == []

      assert {"/host/expect_diff/reasons/0", "missing required to_state"} in errors(
               "case.json",
               with_reasons.([%{"reason" => "state_mapped", "state" => "awaiting_pickup"}])
             )

      assert "/host/expect_diff/reasons/0/t_index" in pointers(
               "case.json",
               with_reasons.([%{"reason" => "state_added", "state" => "idle", "t_index" => 1}])
             )

      assert "/host/expect_diff/reasons/0/unexpected" in pointers(
               "case.json",
               with_reasons.([%{"reason" => "state_added", "state" => "idle", "unexpected" => 1}])
             )

      assert "/host/expect_diff/reasons/0/reason" in pointers(
               "case.json",
               with_reasons.([%{"reason" => "state_renamed", "state" => "idle"}])
             )
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

    # sabotage: upstream's modified property deleted from case.json -> red on
    # the accepting half; its "minLength": 1 deleted -> red on the empty notice
    test "an upstream may carry a non-empty notice that the document was changed" do
      scion = fixture("case-scion.json")

      assert errors("case.json", put_in(scion, ["upstream", "modified"], "lines 1-2 deleted")) ==
               []

      assert "/upstream/modified" in pointers(
               "case.json",
               put_in(scion, ["upstream", "modified"], "")
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
      for name <-
            ~w(case-scion.json case-w3c.json case-statifier.json case-statifier-accepts.json
               case-statifier-diff.json) do
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

  describe "manifest.json carries no version" do
    # sabotage: a statifier_version property added back to manifest.json -> red
    test "refuses a statifier_version, because a claim is pinned by hash and tag" do
      assert "/statifier_version" in pointers(
               "manifest.json",
               Map.put(fixture("manifest.json"), "statifier_version", "2.5.0")
             )
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
