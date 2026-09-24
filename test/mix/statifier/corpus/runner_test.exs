defmodule Mix.Statifier.Corpus.RunnerTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.Corpus.Runner

  # run_paths/2 against the repository's own authored cases, and against a
  # scratch root holding one of them, so a path is read both relative to the
  # project root and already joined to another root. The session runtime is
  # the one test_helper.exs places.

  setup :setup_tmp_dir

  @case_path "conformance/cases/send/registered_immediate.json"

  describe "run_paths/2" do
    # sabotage: run_paths/2 marking every found case :agree without running it
    # -> red on the edited copy's disagreement
    @tag :isolated_tmp_dir
    test "runs the authored case each path names and reports its outcome", %{tmp_dir: root} do
      assert {:ok, [{@case_path, :agree}]} = Runner.run_paths([@case_path], ".")

      dir = Path.join(root, "conformance/cases/send")
      File.mkdir_p!(dir)

      for ext <- ~w(.json .scxml),
          do:
            File.cp!(
              "conformance/cases/send/registered_immediate#{ext}",
              Path.join(dir, "registered_immediate#{ext}")
            )

      json = Path.join(dir, "registered_immediate.json")
      File.write!(json, String.replace(File.read!(json), ~s|"imp-1"|, ~s|"imp-2"|))

      assert {:ok, [{^json, {:disagree, message}}]} = Runner.run_paths([json], root)
      assert message =~ "Expected the sends handed"
    end

    # sabotage: run_paths/2 passing a path that names no case -> red
    test "a path naming no authored case disagrees, naming itself" do
      missing = "conformance/cases/send/no_such_case.json"

      assert {:ok, [{@case_path, :agree}, {^missing, {:disagree, message}}]} =
               Runner.run_paths([@case_path, missing], ".")

      assert message == "#{missing} names no authored case"
    end

    # sabotage: run_paths/2 treating an Authored.read/1 refusal as no cases
    # -> red, the malformed tree is not refused
    @tag :isolated_tmp_dir
    test "a malformed case tree is refused as the reader refuses it", %{tmp_dir: root} do
      dir = Path.join(root, "conformance/cases/send")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "lonely.json"), "{}")

      assert {:error, message} = Runner.run_paths([Path.join(dir, "lonely.json")], root)
      assert message =~ "the authored cases are malformed"
    end
  end
end
