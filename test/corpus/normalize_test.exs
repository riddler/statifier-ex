defmodule Corpus.NormalizeTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "tools/corpus/normalize.exs"]))

  # sabotage: n/a - generator tooling (tools/corpus/), not lib/ behavior

  describe "identifier/1" do
    test "splits camelCase and acronym boundaries" do
      assert Cases.Normalize.identifier("actionSend") == "action_send"
      assert Cases.Normalize.identifier("documentOrder") == "document_order"
      assert Cases.Normalize.identifier("SCXMLEventProcessor") == "scxml_event_processor"
      assert Cases.Normalize.identifier("SelectingTransitions") == "selecting_transitions"

      assert Cases.Normalize.identifier("TestConditionalTransition") ==
               "test_conditional_transition"
    end

    test "collapses non-identifier separators" do
      assert Cases.Normalize.identifier("more-parallel") == "more_parallel"
      assert Cases.Normalize.identifier("hierarchy+documentOrder") == "hierarchy_document_order"
      assert Cases.Normalize.identifier("ecma-profile") == "ecma_profile"
    end

    test "leaves already-idiomatic names alone" do
      assert Cases.Normalize.identifier("atom3_basic_tests") == "atom3_basic_tests"
      assert Cases.Normalize.identifier("cond_js") == "cond_js"
      assert Cases.Normalize.identifier("test403a") == "test403a"
    end

    test "splits the known no-case-boundary upstream names" do
      assert Cases.Normalize.identifier("onentry") == "on_entry"
      assert Cases.Normalize.identifier("onexit") == "on_exit"
    end

    test "is idempotent" do
      for name <- ["actionSend", "onentry", "hierarchy+documentOrder", "atom3_basic_tests"] do
        once = Cases.Normalize.identifier(name)
        assert Cases.Normalize.identifier(once) == once
      end
    end
  end
end
