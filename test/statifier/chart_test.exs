defmodule Statifier.ChartTest do
  use ExUnit.Case, async: true

  alias Statifier.{Chart, Compiler, Lowering, Machine, Parser}
  alias Statifier.Machine.Identity

  @xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
              </onentry>
          </state>
      </state>
  </scxml>
  """

  # One state added relative to @xml - an identity-mismatch fixture, not a
  # whitespace edit.
  @xml_one_state_added """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
      <datamodel>
          <data id="count" expr="0"/>
      </datamodel>
      <state id="p" initial="a">
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <assign location="count" expr="count + 1"/>
              </onentry>
          </state>
      </state>
      <state id="extra"/>
  </scxml>
  """

  # A namespace-less root - compiles only under `invoke_content_markup: true`
  # (ADR-0042), the same leniency an `<invoke><content>` slice needs.
  @xml_namespace_less """
  <scxml version="1.0" initial="a">
      <state id="a"/>
  </scxml>
  """

  defp compile!(xml, opts \\ []) do
    {:ok, machine} = Statifier.compile(xml, opts)
    machine
  end

  # A Machine built by the raw pipeline stages rather than `Statifier.compile/2`
  # - carries no `identity` and no `source`, exactly like a chart compiled
  # before st-i7y7 landed.
  defp compile_without_identity!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  describe "to_binary/1 then from_binary/1 round trip" do
    # sabotage: `check_identity/2`'s success branch is changed from
    # `{:ok, machine}` to `:ok` -> this test reddens with a `MatchError` on
    # `assert {:ok, decoded} = Chart.from_binary(blob)` instead of decoding
    # the recompiled Machine
    test "reproduces the whole Machine struct" do
      machine = compile!(@xml)

      assert {:ok, blob} = Chart.to_binary(machine)
      assert {:ok, decoded} = Chart.from_binary(blob)
      assert decoded == machine
    end
  end

  describe "compile_opts round trip" do
    # sabotage: `to_binary/1`'s written tuple hardcodes `[]` in place of
    # `opts` -> this test reddens because the recompiled source, which only
    # compiles under `invoke_content_markup: true`, now fails to compile and
    # `from_binary/1` returns `{:error, {:compile_failed, _}}` instead of
    # `{:ok, ^machine}`
    test ":invoke_content_markup round-trips and lets the source recompile" do
      machine = compile!(@xml_namespace_less, invoke_content_markup: true)

      assert {:ok, blob} = Chart.to_binary(machine)
      assert {:ok, decoded} = Chart.from_binary(blob)
      assert decoded == machine
    end

    # sabotage: `from_binary/1`'s `recompile(source, opts)` call is changed
    # to `recompile(source, invoke_content_markup: true)` (hardcode the
    # option instead of passing the decoded `opts` through) -> this test
    # reddens because the stripped-opts blob's source now compiles
    # successfully instead of returning `{:error, {:compile_failed, _}}`
    test "a blob with :invoke_content_markup stripped fails to recompile" do
      machine = compile!(@xml_namespace_less, invoke_content_markup: true)
      identity = Machine.identity(machine)

      stripped_blob =
        :erlang.term_to_binary(
          {:statifier_chart, Chart.format_version(), identity, @xml_namespace_less, []}
        )

      assert {:error, {:compile_failed, errors}} = Chart.from_binary(stripped_blob)
      assert is_list(errors)
    end

    # sabotage: same mutation as the test above (`to_binary/1`'s written
    # tuple hardcodes `[]` in place of `opts`) -> this test reddens because
    # the recompiled source no longer carries `chart_name`/`chart_version`,
    # so the reloaded identity's `name`/`version` come back `nil` instead of
    # "traffic-light"/"3"
    test ":chart_name and :chart_version round-trip and reach the reloaded identity" do
      machine = compile!(@xml, chart_name: "traffic-light", chart_version: "3")

      assert {:ok, blob} = Chart.to_binary(machine)
      assert {:ok, decoded} = Chart.from_binary(blob)

      assert Machine.identity(decoded) == Machine.identity(machine)
      assert Machine.identity(decoded).name == "traffic-light"
      assert Machine.identity(decoded).version == "3"
    end
  end

  describe "the blob carries no compiled term" do
    # sabotage: n/a - this test asserts a structural property of
    # `to_binary/1`'s output (no `Predicator.Compiled` byte sequence, a
    # five-tuple envelope) rather than a behavior any single mutation of
    # `lib/` code would flip without also breaking the round-trip test above
    test "contains no Predicator.Compiled tag and decodes to a binary + keyword payload" do
      machine = compile!(@xml)

      assert {:ok, blob} = Chart.to_binary(machine)
      assert :binary.match(blob, "Predicator.Compiled") == :nomatch

      assert {:statifier_chart, version, %Identity{}, source, opts} =
               :erlang.binary_to_term(blob)

      assert version == Chart.format_version()
      assert is_binary(source)
      assert Keyword.keyword?(opts)
    end
  end

  describe "to_binary/1 on an unidentified chart" do
    # sabotage: n/a - this fixture (a `Compiler.compile/1`-built Machine,
    # bypassing `Statifier.compile/2` entirely) carries neither `identity`
    # nor `source`, so `to_binary/1`'s `source: nil` clause alone already
    # covers it; the identity-specific sabotage lives on the test below,
    # which forces only `identity` to `nil` and leaves `source` present
    test "returns {:error, :unidentified_chart} for a Machine with no identity or source" do
      machine = compile_without_identity!(@xml)

      assert machine.identity == nil
      assert machine.source == nil
      assert Chart.to_binary(machine) == {:error, :unidentified_chart}
    end

    # sabotage: `to_binary/1`'s `identity: nil` guard clause is dropped, so
    # a `nil`-identity Machine (with `source` still present) falls through
    # to the general clause instead -> this test reddens because
    # `to_binary/1` returns `{:ok, _}` instead of
    # `{:error, :unidentified_chart}`
    test "returns {:error, :unidentified_chart} for a Machine with source but no identity" do
      machine = %Machine{compile!(@xml) | identity: nil}

      assert Chart.to_binary(machine) == {:error, :unidentified_chart}
    end
  end

  describe "from_binary/1 format version checks" do
    # sabotage: `check_version/1`'s exact-match clause head is widened from
    # `defp check_version(@format_version)` to `defp check_version(_version)`
    # (accept any version) -> this test reddens because a blob whose version
    # integer is bumped to 99 now recompiles and loads instead of returning
    # `{:error, {:unsupported_format_version, 99}}`
    test "a blob whose version integer is bumped returns {:error, {:unsupported_format_version, 99}}" do
      machine = compile!(@xml)
      identity = Machine.identity(machine)

      future_blob =
        :erlang.term_to_binary({:statifier_chart, 99, identity, @xml, []})

      assert Chart.from_binary(future_blob) == {:error, {:unsupported_format_version, 99}}
    end
  end

  describe "from_binary/1 on a foreign or malformed blob" do
    # sabotage: `from_binary/1`'s catch-all `_other -> {:error,
    # :not_a_statifier_blob}` clause's returned atom is changed to
    # `:invalid_blob` -> all three assertions below redden because the
    # actual returned error atom no longer matches
    test "a foreign term_to_binary blob returns {:error, :not_a_statifier_blob}" do
      assert Chart.from_binary(:erlang.term_to_binary(:hello)) ==
               {:error, :not_a_statifier_blob}
    end

    # sabotage: same mutation as above (`from_binary/1`'s catch-all
    # `_other -> {:error, :not_a_statifier_blob}` clause's returned atom
    # changed to `:invalid_blob`) -> this test reddens too, since a random
    # binary reaches the same catch-all via `safe_decode/1`'s `rescue`
    # clause rather than a non-matching decoded term
    test "a random binary returns {:error, :not_a_statifier_blob} rather than raising" do
      random_binary = :crypto.strong_rand_bytes(64)

      assert Chart.from_binary(random_binary) == {:error, :not_a_statifier_blob}
    end

    # sabotage: `from_binary/1`'s decoded-tuple guard is widened from
    # `is_binary(source) and is_list(opts)` to `true` (accept any shape) ->
    # this test reddens because a source slot carrying an atom instead of a
    # binary now reaches `recompile/2`, which raises a `FunctionClauseError`
    # inside `Statifier.compile/2`'s own `is_binary(source)` guard instead of
    # returning `{:error, :not_a_statifier_blob}`
    test "a well-formed envelope whose source slot is not a binary returns {:error, :not_a_statifier_blob}" do
      machine = compile!(@xml)
      identity = Machine.identity(machine)

      malformed_blob =
        :erlang.term_to_binary(
          {:statifier_chart, Chart.format_version(), identity, :not_a_binary, []}
        )

      assert Chart.from_binary(malformed_blob) == {:error, :not_a_statifier_blob}
    end
  end

  describe "from_binary/1 on source that no longer compiles" do
    # sabotage: `recompile/2`'s `{:error, errors} -> {:error, {:compile_failed,
    # errors}}` clause is changed to `{:error, _errors} -> {:error,
    # :not_a_statifier_blob}` (flatten a compile failure into the generic
    # shape error) -> this test reddens because the returned error no longer
    # matches `{:compile_failed, _}`
    test "returns {:error, {:compile_failed, errors}} carrying compile/2's own errors" do
      machine = compile!(@xml)
      identity = Machine.identity(machine)
      uncompilable_source = "<scxml><state/></scxml>"

      blob =
        :erlang.term_to_binary(
          {:statifier_chart, Chart.format_version(), identity, uncompilable_source, []}
        )

      assert {:error, {:compile_failed, errors}} = Chart.from_binary(blob)
      assert is_list(errors)
      assert errors != []
    end
  end

  describe "from_binary/1 identity checks" do
    # sabotage: `check_identity/2`'s `Identity.matches?/2` branch is
    # replaced with the mismatch branch unconditionally
    # (`{:error, {:identity_mismatch, blob_identity, machine_identity}}`
    # always) -> this test reddens because a blob whose stored source still
    # matches its own stored identity now fails to load
    test "a blob whose stored identity matches its recompiled source succeeds" do
      machine = compile!(@xml)

      assert {:ok, blob} = Chart.to_binary(machine)
      assert {:ok, decoded} = Chart.from_binary(blob)
      assert decoded == machine
    end

    # This is the bead's central test: a chart blob must never silently
    # recompile against an identity that no longer matches its source.
    #
    # sabotage: `check_identity/2`'s condition is inverted (`if
    # !Identity.matches?(...)` instead of `if Identity.matches?(...)`) ->
    # this test reddens because a blob whose identity was swapped for a
    # different chart's now loads successfully instead of returning
    # `{:error, {:identity_mismatch, _, _}}`
    test "a blob whose identity was swapped for another chart's returns {:error, {:identity_mismatch, _, _}}" do
      machine = compile!(@xml)
      other_machine = compile!(@xml_one_state_added)

      swapped_blob =
        :erlang.term_to_binary(
          {:statifier_chart, Chart.format_version(), Machine.identity(other_machine), @xml, []}
        )

      assert {:error, {:identity_mismatch, expected, actual}} = Chart.from_binary(swapped_blob)
      assert expected == Machine.identity(other_machine)
      assert actual == Machine.identity(machine)
    end
  end

  describe "format_version/0" do
    # sabotage: `format_version/0` is changed to return `@format_version +
    # 1` instead of `@format_version` -> this test reddens because the
    # returned value (2) no longer equals the version tag actually written
    # into every blob by `to_binary/1`
    test "matches the version tag to_binary/1 writes" do
      machine = compile!(@xml)

      assert {:ok, blob} = Chart.to_binary(machine)
      assert {:statifier_chart, version, _identity, _source, _opts} = :erlang.binary_to_term(blob)
      assert version == Chart.format_version()
    end
  end

  describe "blob size" do
    # sabotage: n/a - this test asserts a structural byte-size property of
    # `to_binary/1`'s output (a binary source is always smaller than the
    # full compiled Machine term for a chart with any states or
    # transitions), not a specific `lib/` branch a single mutation would
    # flip without also breaking the round-trip test above
    test "the blob is smaller than term_to_binary(machine) for the same chart" do
      machine = compile!(@xml)

      assert {:ok, blob} = Chart.to_binary(machine)
      naive_size = byte_size(:erlang.term_to_binary(machine))

      assert byte_size(blob) < naive_size
    end
  end
end
