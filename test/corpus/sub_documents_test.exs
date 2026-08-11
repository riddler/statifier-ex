defmodule Corpus.SubDocumentsTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "tools/corpus/scxml_w3/sub_documents.exs"]))

  # sabotage: n/a - generator tooling (tools/corpus/), not lib/ behavior

  describe "ids_from_string/1" do
    test "a start/dep pair yields exactly the dep id" do
      manifest = """
      <test id="216" conformance="mandatory" manual="false">
      <start uri="216/test216.txml"/>
      <dep uri="216/test216sub1.txml"/>
      </test>
      """

      assert Cases.SubDocuments.ids_from_string(manifest) == MapSet.new(["test216sub1"])
    end

    test "a .txt dep is not returned" do
      manifest = """
      <test id="446" conformance="mandatory" manual="false">
      <start uri="446/test446.txml"/>
      <dep uri="446/test446.txt"/>
      </test>
      """

      assert Cases.SubDocuments.ids_from_string(manifest) == MapSet.new()
    end

    test "an id that is both a dep and a start is not returned" do
      manifest = """
      <test id="446" conformance="mandatory" manual="false">
      <start uri="446/test446.txml"/>
      <dep uri="446/test446.txml"/>
      </test>
      """

      result = Cases.SubDocuments.ids_from_string(manifest)

      refute MapSet.member?(result, "test446")
      assert result == MapSet.new()
    end

    test "a manifest with no dep yields an empty set" do
      manifest = """
      <test id="144" conformance="mandatory" manual="false">
      <start uri="144/test144.txml"/>
      </test>
      """

      assert Cases.SubDocuments.ids_from_string(manifest) == MapSet.new()
    end

    test "the five real manifest sub-document entries yield exactly those five ids" do
      manifest = """
      <test id="216" conformance="mandatory" manual="false">
      <start uri="216/test216.txml"/>
      <dep uri="216/test216sub1.txml"/>
      </test>
      <test id="226" conformance="mandatory" manual="false">
      <start uri="226/test226.txml"/>
      <dep uri="226/test226sub1.txml"/>
      </test>
      <test id="239" conformance="mandatory" manual="false">
      <start uri="239/test239.txml"/>
      <dep uri="239/test239sub1.txml"/>
      </test>
      <test id="242" conformance="mandatory" manual="false">
      <start uri="242/test242.txml"/>
      <dep uri="242/test242sub1.txml"/>
      </test>
      <test id="276" conformance="mandatory" manual="false">
      <start uri="276/test276.txml"/>
      <dep uri="276/test276sub1.txml"/>
      </test>
      """

      assert Cases.SubDocuments.ids_from_string(manifest) ==
               MapSet.new([
                 "test216sub1",
                 "test226sub1",
                 "test239sub1",
                 "test242sub1",
                 "test276sub1"
               ])
    end
  end
end
