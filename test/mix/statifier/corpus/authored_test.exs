defmodule Mix.Statifier.Corpus.AuthoredTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.Corpus.{Authored, Upstream}

  # The reader of conformance/cases/, against a scratch root per test.

  setup :setup_tmp_dir

  @scxml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="idle">
      <state id="idle"/>
  </scxml>
  """

  @fields %{
    "description" => "An idle chart.",
    "initial_configuration" => ["idle"],
    "steps" => [],
    "host" => %{"send_types" => ["myapp:sink"], "expect_sends" => []}
  }

  defp put_case(root, relative, fields \\ @fields, scxml \\ @scxml) do
    base = Path.join([root, "conformance/cases", relative])
    File.mkdir_p!(Path.dirname(base))
    if fields, do: File.write!(base <> ".json", JSON.encode!(fields))
    if scxml, do: File.write!(base <> ".scxml", scxml)
  end

  describe "read/1" do
    @tag :isolated_tmp_dir
    # sabotage: read/1's `else` arm returns an error for a missing directory
    # -> red
    test "no conformance/cases/ directory is no authored case", %{tmp_dir: root} do
      assert Authored.read(root) == {:ok, []}
    end

    @tag :isolated_tmp_dir
    # sabotage: read_case/2 taking `spec` from the file name instead of the
    # directory -> red on id and spec
    test "derives every field a person does not write, sorted by id", %{tmp_dir: root} do
      put_case(root, "send/zeta")
      put_case(root, "send/alpha")

      assert {:ok, [alpha, zeta]} = Authored.read(root)
      assert zeta["id"] == "statifier/send/zeta"

      assert alpha ==
               Map.merge(@fields, %{
                 "id" => "statifier/send/alpha",
                 "suite" => "statifier",
                 "spec" => "send",
                 "conformance" => nil,
                 "source" => @scxml,
                 "required_features" => Upstream.required_features(@scxml)
               })
    end

    @tag :isolated_tmp_dir
    # sabotage: all_paired/2's partner clause removed -> red, the lone
    # .scxml passes
    test "refuses a .json or .scxml file without its partner", %{tmp_dir: root} do
      put_case(root, "send/lonely", nil)
      put_case(root, "send/unwritten", @fields, nil)

      assert {:error, message} = Authored.read(root)
      assert message =~ "conformance/cases/send/lonely.scxml has no lonely.json beside it"
      assert message =~ "conformance/cases/send/unwritten.json has no unwritten.scxml beside it"
    end

    @tag :isolated_tmp_dir
    # sabotage: all_paired/2's depth clause removed -> red
    test "refuses a case outside exactly one spec directory, and a stray file", %{tmp_dir: root} do
      put_case(root, "top")
      put_case(root, "send/deeper/nested")
      File.write!(Path.join(root, "conformance/cases/send/notes.txt"), "")

      assert {:error, message} = Authored.read(root)
      assert message =~ "conformance/cases/top.json is not in exactly one spec directory"
      assert message =~ "conformance/cases/send/deeper/nested.json is not in exactly one spec"

      assert message =~
               "conformance/cases/send/notes.txt is neither a case's .json nor its .scxml"
    end

    @tag :isolated_tmp_dir
    # sabotage: written_fields/2 accepting any key set ({_, _} -> :ok) -> red
    test "refuses a field a case does not write, and a missing one", %{tmp_dir: root} do
      put_case(root, "send/extra", Map.put(@fields, "id", "statifier/send/other"))
      assert {:error, message} = Authored.read(root)

      assert message ==
               "conformance/cases/send/extra.json carries a field a case does not write: id"

      File.rm_rf!(Path.join(root, "conformance/cases"))
      put_case(root, "send/short", Map.delete(@fields, "steps"))
      assert {:error, "conformance/cases/send/short.json is missing: steps"} = Authored.read(root)
    end

    @tag :isolated_tmp_dir
    # sabotage: segments/2 returning :ok -> red
    test "refuses a name the case id pattern does not allow", %{tmp_dir: root} do
      put_case(root, "send/_hidden")

      assert {:error, message} = Authored.read(root)

      assert message =~
               "conformance/cases/send/_hidden.json: its directory and name must each match"
    end

    @tag :isolated_tmp_dir
    # sabotage: decode/2's non-object clause removed -> red (a list case
    # reaches written_fields/2 and raises)
    test "refuses invalid JSON and a JSON value that is not an object", %{tmp_dir: root} do
      put_case(root, "send/list", ["not", "an", "object"])

      assert {:error, "conformance/cases/send/list.json is not a JSON object"} =
               Authored.read(root)

      File.write!(Path.join(root, "conformance/cases/send/list.json"), "{")

      assert {:error, "invalid JSON in conformance/cases/send/list.json" <> _reason} =
               Authored.read(root)
    end
  end
end
