Code.require_file("tools/corpus/scxml_w3/check_exprs.exs", File.cwd!())

defmodule Corpus.CheckExprsTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Corpus.CheckExprs

  setup :setup_tmp_dir

  describe "check/2" do
    # sabotage: swap Predicator.compile for Predicator.context_location in the
    # :expression clause -> "Var1 + 1" would resolve as a location and red
    test "a valid expr compiles" do
      assert {:ok, _instructions} = CheckExprs.check(:expression, "Var1 + 1")
    end

    # sabotage: drop the :location clause's error branch (always return {:ok, []})
    # -> a literal location would wrongly report as valid, red
    test "an invalid location fails" do
      assert {:error, _reason} = CheckExprs.check(:location, "42")
    end
  end

  describe "check_file/2" do
    # sabotage: check_file/2 ignoring the allowlist argument (always using
    # CheckExprs.allowlist/0) -> the file-local override below would land in
    # :unexpected instead of :expected, red
    @tag :isolated_tmp_dir
    test "an allowlisted invalid value is reported as expected, not unexpected", %{
      tmp_dir: tmp_dir
    } do
      path = write(tmp_dir, "test900.scxml", ~s|<scxml><transition location="42"/></scxml>|)

      report = CheckExprs.check_file(path, %{{:location, "42"} => {"fixture", ["test900"]}})

      assert report.checked == 1
      assert report.expected == [{:location, "location", "42"}]
      assert report.unexpected == []
    end

    # sabotage: drop the Map.has_key?(allowlist, ...) branch entirely, treating
    # every compile/resolve failure as unexpected -> the allowlisted case above
    # would land in :unexpected too, red (this test pins the un-allowlisted case)
    @tag :isolated_tmp_dir
    test "an un-allowlisted invalid value is reported as unexpected", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "test901.scxml", ~s|<scxml><transition location="42"/></scxml>|)

      report = CheckExprs.check_file(path, %{})

      assert report.checked == 1
      assert report.expected == []
      assert report.unexpected == [{:location, "location", "42"}]
    end
  end

  describe "run/3" do
    @describetag :isolated_tmp_dir

    setup %{tmp_dir: tmp_dir} do
      exclusions_path = Path.join(tmp_dir, "exclusions.exs")
      %{exclusions_path: exclusions_path}
    end

    # sabotage: drop the Map.has_key?(exclusions, test_id) filter in
    # Enum.split_with -> the excluded fixture below would be checked instead of
    # skipped, red (files_skipped would read 0)
    test "an excluded test is skipped, not checked", %{
      tmp_dir: tmp_dir,
      exclusions_path: exclusions_path
    } do
      write(tmp_dir, "test902.scxml", ~s|<scxml><data expr="Var1 + 1"/></scxml>|)
      File.write!(exclusions_path, ~s|%{"test902" => {:needs_script, "fixture"}}|)

      report = CheckExprs.run(tmp_dir, exclusions_path, %{})

      assert report.files_checked == 0
      assert report.files_skipped == 1
      assert report.expressions_checked == 0
    end

    # sabotage: build fired_keys from the allowlist itself instead of from
    # expected_failures -> stale_allowlist would always be empty, red
    test "an allowlist entry that never fires is reported as stale", %{
      tmp_dir: tmp_dir,
      exclusions_path: exclusions_path
    } do
      write(tmp_dir, "test903.scxml", ~s|<scxml><data expr="Var1 + 1"/></scxml>|)
      File.write!(exclusions_path, "%{}")

      report =
        CheckExprs.run(tmp_dir, exclusions_path, %{
          {:location, "never fires"} => {"fixture", ["nobody"]}
        })

      assert report.files_checked == 1
      assert report.unexpected_failures == []
      assert report.stale_allowlist == [{:location, "never fires"}]
      refute CheckExprs.ok?(report)
    end
  end

  defp write(tmp_dir, name, content) do
    path = Path.join(tmp_dir, name)
    File.write!(path, content)
    path
  end
end
