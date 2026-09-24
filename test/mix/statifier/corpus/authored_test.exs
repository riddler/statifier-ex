defmodule Mix.Statifier.Corpus.AuthoredTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  doctest Mix.Statifier.Corpus.Authored

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

  describe "read/1 with a second chart" do
    @to_scxml """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="ready_for_pickup">
        <state id="ready_for_pickup"/>
    </scxml>
    """

    defp put_second_chart(root, relative, scxml \\ @to_scxml) do
      File.write!(Path.join([root, "conformance/cases", relative]) <> ".to.scxml", scxml)
    end

    @tag :isolated_tmp_dir
    # sabotage: put_to_source/3 returning the fields unchanged -> red
    test "reads <name>.to.scxml into the case's host as to_source", %{tmp_dir: root} do
      put_case(root, "diff/hold")
      put_second_chart(root, "diff/hold")

      assert {:ok, [hold]} = Authored.read(root)
      assert hold["id"] == "statifier/diff/hold"
      assert hold["source"] == @scxml
      assert hold["host"] == Map.put(@fields["host"], "to_source", @to_scxml)
    end

    @tag :isolated_tmp_dir
    # sabotage: put_to_source/3's Map.update/4 default replaced by the
    # fields' own host (nil) -> red
    test "gives a case with no host object one holding only to_source", %{tmp_dir: root} do
      put_case(root, "diff/hold", Map.delete(@fields, "host"))
      put_second_chart(root, "diff/hold")

      assert {:ok, [hold]} = Authored.read(root)
      assert hold["host"] == %{"to_source" => @to_scxml}
    end

    @tag :isolated_tmp_dir
    # sabotage: all_paired/2's second-chart clause removed -> the lone
    # second chart falls to the .to name clause -> red on the message
    test "refuses a second chart without its case's .json and .scxml", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "conformance/cases/diff"))
      put_second_chart(root, "diff/lonely")

      assert {:error, message} = Authored.read(root)
      assert message =~ "conformance/cases/diff/lonely.to.scxml has no lonely.json beside it"
      assert message =~ "conformance/cases/diff/lonely.to.scxml has no lonely.scxml beside it"
    end

    @tag :isolated_tmp_dir
    # sabotage: put_to_source/3's first clause removed -> the written value
    # is overwritten silently -> red
    test "refuses a case JSON that writes to_source itself", %{tmp_dir: root} do
      put_case(root, "diff/hold", put_in(@fields, ["host", "to_source"], @to_scxml))
      put_second_chart(root, "diff/hold")

      assert {:error, message} = Authored.read(root)

      assert message ==
               "conformance/cases/diff/hold.json writes host.to_source, " <>
                 "which is read from its .to.scxml file"
    end

    @tag :isolated_tmp_dir
    # sabotage: all_paired/2's `.to` name clause removed -> the case reads
    # -> red
    test "refuses a case whose name ends in .to", %{tmp_dir: root} do
      put_case(root, "diff/hold.to")

      assert {:error, message} = Authored.read(root)
      assert message =~ "conformance/cases/diff/hold.to.json names a case ending in .to"
    end
  end
end
