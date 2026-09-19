defmodule Mix.Tasks.Statifier.CorpusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Tasks.Statifier.Corpus

  # The task is the emitter's command line: these tests drive it over the
  # emitter's fixture tree (test/fixtures/corpus_emitter), with the project
  # root moved to a scratch directory through execute/2's :root option, and
  # prove that every refusal reaches the caller as a raised Mix.Error - a
  # non-zero exit under `mix` - carrying the sentence.

  # The two tools/corpus scripts the emitter loads, required from this
  # repository once, as their own tests do: the copies under each fixture root
  # exist for the emitter's presence checks and are never loaded a second time.
  for script <- ~w(tools/corpus/normalize.exs tools/corpus/scxml_w3/sub_documents.exs),
      do: Code.require_file(script)

  @fixtures "test/fixtures/corpus_emitter"
  @scratch Path.join(@fixtures, "scratch")
  @copied ~w(conformance/LICENSES tools/corpus/normalize.exs tools/corpus/scxml_w3/sub_documents.exs)

  setup :setup_tmp_dir

  setup %{tmp_dir: root} do
    File.cp_r!(Path.join(@fixtures, "root"), root)

    for path <- @copied do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(path, target)
    end

    %{root: root}
  end

  describe "execute/2" do
    @tag :isolated_tmp_dir
    # sabotage: execute/2 emitting under --check (if false) -> red, the check
    # line is never printed
    test "emits, then checks with the upstream tree absent, printing what each found", %{
      root: root
    } do
      emitted =
        capture_io(fn -> assert :ok = Corpus.execute(["--scratch", @scratch], root: root) end)

      assert emitted =~ "scion: ran 2 case(s), 1 agree with their expectation"
      assert emitted =~ "outside the ratchet (2):"

      assert emitted =~
               ~s|  w3c/test9003: disagrees - Expected active states ["pass"], but got ["fail"]|

      assert emitted =~ "wrote conformance/manifest.json"

      absent = Path.join(root, "no-upstream")

      checked =
        capture_io(fn ->
          assert :ok = Corpus.execute(["--check", "--scratch", absent], root: root)
        end)

      assert checked =~ "w3c: checked 2 case(s), 1 agree with their expectation"
      assert checked =~ "upstream comparison skipped: no upstream tree at #{absent}"
      refute checked =~ "wrote "
    end

    @tag :isolated_tmp_dir
    # sabotage: print/2's :compared clause printing nothing -> red
    test "says so when the corpus matched the upstream tree", %{root: root} do
      capture_io(fn -> Corpus.execute(["--scratch", @scratch], root: root) end)

      checked =
        capture_io(fn ->
          assert :ok = Corpus.execute(["--check", "--scratch", @scratch], root: root)
        end)

      assert checked =~ "upstream comparison: the corpus matches the upstream tree"
    end

    @tag :isolated_tmp_dir
    # sabotage: Exclusions.parse/3 skipping unique_keys/2 -> red
    test "returns the exclusion reader's refusal as its sentence", %{root: root} do
      path = Path.join(root, "tools/corpus/scion/exclusions.exs")
      File.write!(path, ~s|%{"retired" => {:a, "one"}, "retired" => {:b, "two"}}|)

      assert {:error, message} = Corpus.execute(["--scratch", @scratch], root: root)
      assert message =~ ~s|repeats the key(s) ["retired"]|
    end
  end

  describe "run/1" do
    @tag :isolated_tmp_dir
    # sabotage: run/1 printing the reason with Mix.shell().error/1 instead of
    # Mix.raise/1 -> red
    test "exits non-zero with the reader's sentence when the sub-document list is refused", %{
      root: root
    } do
      scratch = Path.join(root, "scratch")
      File.cp_r!(@scratch, scratch)
      manifest = Path.join(scratch, "scxml_w3/cases/manifest.xml")
      File.write!(manifest, String.replace(File.read!(manifest), ~r/<dep [^>]*>\n/, ""))

      assert_raise Mix.Error,
                   ~r/names no sub-document; an empty sub-document list is refused/,
                   fn ->
                     Corpus.run(["--scratch", scratch])
                   end
    end

    @tag :isolated_tmp_dir
    # sabotage: upstream_present/1 returning :ok -> red (the run fails later,
    # on another sentence)
    test "exits non-zero naming mise run corpus:fetch when the upstream tree is absent", %{
      root: root
    } do
      assert_raise Mix.Error, ~r/the upstream tree is absent .*mise run corpus:fetch/, fn ->
        Corpus.run(["--scratch", Path.join(root, "no-upstream")])
      end
    end
  end
end
