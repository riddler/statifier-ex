defmodule Mix.Statifier.Corpus.UpstreamTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.Corpus.Upstream

  # Upstream.read/3 over a scratch tree built in a temporary directory: two
  # W3C documents, one naming the Basic HTTP Event I/O Processor as a send
  # type and one not, and an empty SCION tree.

  setup :setup_tmp_dir

  @basic_http "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"

  @manifest """
  <?xml version="1.0" encoding="UTF-8"?>
  <assertions>
  <assert id="1">
  <test id="9101" conformance="optional" manual="false">
  <start uri="9101/test9101.txml"/>
  </test>
  <test id="9102" conformance="optional" manual="false">
  <start uri="9102/test9102.txml"/>
  </test>
  </assert>
  </assertions>
  """

  defp document(send) do
    """
    <?xml version="1.0" encoding="UTF-8"?><scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="s0">
    <state id="s0">
      <onentry>#{send}</onentry>
      <transition event="*" target="pass"/>
    </state>
    <final id="pass"/>
    </scxml>
    """
  end

  defp scratch(root) do
    File.mkdir_p!(Path.join(root, "scion/cases"))
    w3c = Path.join(root, "scxml_w3/cases")
    dir = Path.join(w3c, "optional/processors")
    File.mkdir_p!(dir)
    File.write!(Path.join(w3c, "manifest.xml"), @manifest)

    File.write!(
      Path.join(dir, "test9101.scxml"),
      document(
        ~s|<send type="#{@basic_http}" targetexpr="_ioprocessors['basichttp']['location']" event="e"/>|
      )
    )

    File.write!(Path.join(dir, "test9102.scxml"), document(~s|<send event="e"/>|))

    for id <- ~w(test9101 test9102),
        do: File.write!(Path.join(dir, id <> ".description"), "a description")

    root
  end

  describe "read/3" do
    # sabotage: w3c_predicator_case/6 not calling put_host/1 -> test9101
    # carries no host object -> red
    @tag :isolated_tmp_dir
    test "a W3C document naming the Basic HTTP processor as a send type declares it as the host's",
         %{tmp_dir: root} do
      assert {:ok, [with_processor, without]} = Upstream.read(scratch(root), [], [])

      assert with_processor["id"] == "w3c/test9101"
      assert with_processor["host"] == %{"event_io_processors" => [@basic_http]}

      assert without["id"] == "w3c/test9102"
      refute Map.has_key?(without, "host")
    end
  end
end
