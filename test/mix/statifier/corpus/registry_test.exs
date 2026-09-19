defmodule Mix.Statifier.Corpus.RegistryTest do
  use ExUnit.Case, async: true

  doctest Mix.Statifier.Corpus.Registry

  alias Mix.Statifier.Corpus.Registry

  # A small corpus in the advertising domain: two SCION cases, a mandatory
  # and an optional W3C case, and a statifier case, which has no generated
  # test module and so no path the ratchet could name.
  @cases [
    %{"id" => "scion/ads/impression", "suite" => "scion"},
    %{"id" => "scion/ads/click", "suite" => "scion"},
    %{"id" => "w3c/test9001", "suite" => "w3c", "conformance" => "mandatory"},
    %{"id" => "w3c/test9004", "suite" => "w3c", "conformance" => "optional"},
    %{"id" => "statifier/ads/frequency_cap", "suite" => "statifier"}
  ]

  @hash "sha256:" <> String.duplicate("0", 64)

  defp path(%{"suite" => "statifier"}), do: nil
  defp path(%{"id" => id}), do: "test/" <> id <> "_test.exs"

  defp derive(ratchet, cases \\ @cases), do: Registry.derive(cases, ratchet, @hash, &path/1)

  describe "derive/4" do
    # sabotage: derive/4 sorting entries by case_id descending -> red
    test "writes one entry per ratchet path, sorted by suite then case id" do
      assert {:ok, registry} =
               derive([
                 "test/w3c/test9001_test.exs",
                 "test/scion/ads/impression_test.exs",
                 "test/scion/ads/click_test.exs"
               ])

      assert registry == %{
               "implementation" => "statifier-ex",
               "corpus_hash" => @hash,
               "claims" => ["scion", "w3c-mandatory"],
               "entries" => [
                 %{"case_id" => "scion/ads/click", "suite" => "scion"},
                 %{"case_id" => "scion/ads/impression", "suite" => "scion"},
                 %{"case_id" => "w3c/test9001", "suite" => "w3c"}
               ]
             }
    end

    # sabotage: claim/1 returning the suite for a W3C case -> red
    test "splits the W3C claim by conformance class and claims no suite without entries" do
      assert {:ok, %{"claims" => ["w3c-optional"]}} = derive(["test/w3c/test9004_test.exs"])
    end

    # sabotage: claimed/2 skipping a path with no case instead of refusing -> red
    test "refuses a ratchet path that names no corpus case, naming it" do
      assert {:error, message} =
               derive(["test/scion/ads/impression_test.exs", "test/scion/ads/retired_test.exs"])

      assert message =~ "does not map to exactly one corpus case"
      assert message =~ "test/scion/ads/retired_test.exs: names no corpus case"
      refute message =~ "impression"
    end

    # sabotage: claimed/2 taking the first case of a shared path ([one | _]) -> red
    test "refuses a ratchet path two corpus cases share, naming both" do
      cases = @cases ++ [%{"id" => "scion/ads/impression", "suite" => "scion", "copy" => true}]

      assert {:error, message} = derive(["test/scion/ads/impression_test.exs"], cases)

      assert message =~
               "test/scion/ads/impression_test.exs: names scion/ads/impression and scion/ads/impression, not exactly one case"
    end

    # sabotage: claimed/2's first clause returning {:ok, []} -> red
    test "refuses an empty ratchet: a registry of nothing is not a claim" do
      assert derive([]) ==
               {:error, "the ratchet names no corpus case; an empty registry is refused"}
    end

    # sabotage: derive/4 keeping only scion and w3c entries -> red on the
    # second half
    test "a statifier case enters only once the ratchet can name a path for it" do
      every_path = @cases |> Enum.map(&path/1) |> Enum.reject(&is_nil/1)

      assert {:ok, registry} = derive(every_path)
      assert registry["claims"] == ["scion", "w3c-mandatory", "w3c-optional"]
      refute Enum.any?(registry["entries"], &(&1["suite"] == "statifier"))

      named = fn corpus_case -> "test/" <> corpus_case["id"] <> "_test.exs" end
      ratchet = ["test/statifier/ads/frequency_cap_test.exs" | every_path]

      assert {:ok, registry} = Registry.derive(@cases, ratchet, @hash, named)
      assert "statifier" in registry["claims"]

      assert %{"case_id" => "statifier/ads/frequency_cap", "suite" => "statifier"} in registry[
               "entries"
             ]
    end
  end

  describe "encode/1" do
    # sabotage: encode/1 writing the entries with Json.pretty/1 -> red
    test "writes one entry per line, case_id first, so a ratchet is a one-line diff" do
      {:ok, registry} =
        derive(["test/scion/ads/click_test.exs", "test/w3c/test9001_test.exs"])

      assert Registry.encode(registry) == """
             {
               "implementation": "statifier-ex",
               "corpus_hash": "#{@hash}",
               "claims": ["scion","w3c-mandatory"],
               "entries": [
                 {"case_id":"scion/ads/click","suite":"scion"},
                 {"case_id":"w3c/test9001","suite":"w3c"}
               ]
             }
             """

      assert registry |> Registry.encode() |> JSON.decode!() == registry
    end
  end

  describe "stale/2" do
    defp committed(entries),
      do: JSON.encode!(%{"implementation" => "statifier-ex", "entries" => entries})

    # sabotage: stale/2 returning [] for every document -> red
    test "names an entry the corpus lacks and one it holds under another suite" do
      problems =
        [
          %{"case_id" => "scion/ads/click", "suite" => "scion"},
          %{"case_id" => "scion/ads/retired", "suite" => "scion"},
          %{"case_id" => "w3c/test9001", "suite" => "scion"}
        ]
        |> committed()
        |> Registry.stale(@cases)

      assert problems == [
               "scion/ads/retired: in the registry but not in the corpus",
               "w3c/test9001: the registry says suite scion, the corpus says w3c"
             ]
    end

    # sabotage: stale/2 treating "entries": [] as a registry with no stale
    # entry ({:ok, _no_entries} -> []) -> red
    test "refuses a registry with no entries" do
      assert Registry.stale(committed([]), @cases) == [
               "conformance/registry.json has no entries; an empty registry is refused"
             ]

      assert Registry.stale("{}", @cases) == [
               "conformance/registry.json has no entries; an empty registry is refused"
             ]
    end

    # sabotage: stale_entry/2's catch-all clause removed -> red (FunctionClauseError)
    test "names an entry that is not in the entry shape, and invalid JSON" do
      assert [shape] = Registry.stale(committed([%{"id" => "scion/ads/click"}]), @cases)
      assert shape =~ "holds an entry that is not {case_id, suite}"

      assert [json] = Registry.stale("{", @cases)
      assert json =~ "invalid JSON in conformance/registry.json"
    end
  end
end
