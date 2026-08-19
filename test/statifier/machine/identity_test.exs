defmodule Statifier.Machine.IdentityTest do
  use ExUnit.Case, async: true

  alias Statifier.Machine.Identity

  @xml_a """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # Same states as @xml_a, but "a" and "b" swap document position - a
  # reordered-states edit, not a whitespace-only one.
  @xml_reordered """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="b"/>
      <state id="a">
          <transition event="go" target="b"/>
      </state>
  </scxml>
  """

  describe "of_source/2" do
    # sabotage: `of_source/2`'s `content_hash` is changed to a constant
    # `"sha256:" <> String.duplicate("0", 64)` instead of hashing `source` ->
    # this test reddens because two byte-identical sources still produce the
    # same identity, but the identity no longer depends on the source at all,
    # which the next test (different source -> different hash) catches
    # instead; this test alone would stay green under that mutation, so it is
    # paired with the next one to actually pin the hash to the source.
    test "equal source gives equal hash" do
      assert Identity.of_source(@xml_a).content_hash == Identity.of_source(@xml_a).content_hash
    end

    # sabotage: `of_source/2`'s `content_hash` is changed to a constant
    # `"sha256:" <> String.duplicate("0", 64)` instead of hashing `source` ->
    # this test reddens because the reordered document's hash now equals the
    # original's instead of differing from it
    test "a reordered-states edit gives a different hash" do
      refute Identity.of_source(@xml_a).content_hash ==
               Identity.of_source(@xml_reordered).content_hash
    end

    # This is the intended conservative behavior, not a defect: the hash is
    # over the source binary, not a semantic diff, so any byte difference -
    # whitespace included - changes it. A host that wants "no functional
    # change" to mean "same identity" needs a canonicalization step this
    # module deliberately does not perform (see moduledoc: hashing the
    # compiled Machine term instead was rejected precisely because it hides
    # this kind of choice from the caller).
    #
    # sabotage: `of_source/2`'s `content_hash` is changed to a constant
    # `"sha256:" <> String.duplicate("0", 64)` instead of hashing `source` ->
    # this test reddens because the whitespace-only variant's hash now equals
    # the original's instead of differing from it
    test "a whitespace-only edit gives a different hash (conservative by design)" do
      whitespace_only = @xml_a <> "\n"

      refute Identity.of_source(@xml_a).content_hash ==
               Identity.of_source(whitespace_only).content_hash
    end

    # sabotage: `of_source/2`'s `name:` field is hardcoded to `nil` instead of
    # `Keyword.get(opts, :chart_name)` -> this test reddens because the
    # returned identity's `name` no longer carries the option through
    test "chart_name and chart_version ride through" do
      identity = Identity.of_source(@xml_a, chart_name: "traffic-light", chart_version: "3")

      assert %Identity{name: "traffic-light", version: "3"} = identity
    end

    # sabotage: `of_source/2`'s `name:` field reads `Keyword.get(opts,
    # :invoke_content_markup)` instead of `Keyword.get(opts, :chart_name)` ->
    # this test reddens because `name` picks up `true` instead of staying
    # `nil`, showing an unrecognized option would otherwise leak through
    test "unrecognized options (e.g. invoke_content_markup) are ignored" do
      identity = Identity.of_source(@xml_a, invoke_content_markup: true)

      assert %Identity{name: nil, version: nil} = identity
    end
  end

  describe "matches?/2" do
    # sabotage: `matches?/2`'s two-struct clause is changed from `a == b` to
    # `true` unconditionally -> this test's second assertion (identical
    # source, distinct name -> no match) reddens because it now reports a
    # match
    test "true only when content_hash, name, and version all agree" do
      a = Identity.of_source(@xml_a, chart_name: "n", chart_version: "1")
      b = Identity.of_source(@xml_a, chart_name: "n", chart_version: "1")
      c = Identity.of_source(@xml_a, chart_name: "other", chart_version: "1")

      assert Identity.matches?(a, b)
      refute Identity.matches?(a, c)
    end

    # sabotage: `matches?/2`'s catch-all clause is changed from `false` to
    # `is_nil(a) and is_nil(b)` (treat two nils as a match) -> this test's
    # first assertion (`nil, nil`) reddens because it now returns `true`
    test "false whenever either side is nil" do
      identity = Identity.of_source(@xml_a)

      refute Identity.matches?(nil, nil)
      refute Identity.matches?(identity, nil)
      refute Identity.matches?(nil, identity)
    end
  end

  describe "to_binary/1 and from_binary/1" do
    # sabotage: `to_binary/1`'s envelope tuple is changed from
    # `{:statifier_chart_identity, @format_version, identity}` to
    # `{:statifier_chart_identity, @format_version, nil}` (drop the payload)
    # -> this test reddens with `{:error, {:unsupported_format_version, 1}}`
    # instead of `{:ok, ^identity}`, because `from_binary/1`'s first clause no
    # longer matches a `nil` payload against `%__MODULE__{}`
    test "an identity round trips through to_binary/1 and from_binary/1" do
      identity = Identity.of_source(@xml_a, chart_name: "n", chart_version: "1")

      assert {:ok, ^identity} = identity |> Identity.to_binary() |> Identity.from_binary()
    end

    # sabotage: `from_binary/1`'s first clause pattern is loosened from
    # `{:statifier_chart_identity, @format_version, %__MODULE__{} = identity}`
    # to `{:statifier_chart_identity, version, %__MODULE__{} = identity}`
    # (accept any version) -> this test reddens because a bumped version byte
    # now decodes as `{:ok, identity}` instead of the expected
    # `{:error, {:unsupported_format_version, 99}}`
    test "a bumped format version produces its own error" do
      identity = Identity.of_source(@xml_a)
      blob = :erlang.term_to_binary({:statifier_chart_identity, 99, identity})

      assert {:error, {:unsupported_format_version, 99}} = Identity.from_binary(blob)
    end

    # sabotage: `from_binary/1`'s catch-all clause is changed from
    # `_other -> {:error, :not_a_statifier_blob}` to
    # `_other -> {:error, :unsupported_format_version}` (wrong error shape)
    # -> this test reddens because the foreign blob now produces
    # `{:error, :unsupported_format_version}` instead of
    # `{:error, :not_a_statifier_blob}`
    test "a foreign term_to_binary blob produces :not_a_statifier_blob" do
      foreign = :erlang.term_to_binary({:something_else, 1, %{}})

      assert {:error, :not_a_statifier_blob} = Identity.from_binary(foreign)
    end

    # sabotage: `safe_decode/1`'s `rescue ArgumentError -> :error` clause is
    # deleted -> this test reddens with an uncaught `ArgumentError` instead of
    # the expected `{:error, :not_a_statifier_blob}`
    test "garbage bytes produce :not_a_statifier_blob instead of raising" do
      assert {:error, :not_a_statifier_blob} = Identity.from_binary(<<0, 1, 2, 3>>)
    end
  end

  describe "format_version/0" do
    # sabotage: `format_version/0`'s body is changed from `@format_version`
    # to the literal `0` -> this test reddens because it is no longer a
    # positive integer
    test "returns a positive integer" do
      assert Identity.format_version() > 0
    end
  end
end
