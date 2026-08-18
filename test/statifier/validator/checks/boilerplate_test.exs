defmodule Statifier.Validator.Checks.BoilerplateTest do
  use ExUnit.Case, async: true

  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  defp validate!(xml, opts) do
    Validator.validate(lower!(xml), xml, opts)
  end

  describe "check/2 - bad_namespace and bad_version" do
    # sabotage: `check/2` drops the `check_version(document)` half of
    # `check_namespace(document) ++ check_version(document)` -> the
    # boilerplate-free fragment reports only `:bad_namespace`, reddening
    # both the `length(errors) == 2` assertion and the `:bad_version` lookup
    test "a boilerplate-free fragment reports both bad_namespace and bad_version at the start tag" do
      xml = """
      <scxml>
          <state id="a"/>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)
      assert length(errors) == 2

      assert %Error{reason: {:bad_namespace, nil}} = find(errors, :bad_namespace)
      assert %Error{reason: {:bad_version, nil}} = find(errors, :bad_version)

      for error <- errors do
        assert error.location.start_line == 1
      end
    end

    # sabotage: `lower/1`'s `%{document | namespace: uri}` is changed to
    # `%{document | namespace: document.xmlns}`, stamping the literal
    # (unresolved) `xmlns` attribute instead of the resolved URI -> a
    # prefixed root's `xmlns` field is `nil` (only `xmlns:s` was written),
    # so `document.namespace` becomes `nil` instead of the resolved SCXML
    # URI, and this "passes clean" assertion reddens with a spurious
    # `:bad_namespace`
    test "a prefixed root declaring the SCXML namespace passes clean" do
      xml = """
      <s:scxml xmlns:s="http://www.w3.org/2005/07/scxml" version="1.0">
          <s:state id="a"/>
      </s:scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # A bare `xmlns` naming a genuinely foreign namespace never reaches this
    # check through the normal Parser -> Lowering -> Validator pipeline:
    # `Namespace.scxml_vocabulary?/1` (`uri in [nil, @scxml_namespace]`) is
    # the gate `lower/1` itself applies to the root's own resolved name, so
    # a root xmlns pointing anywhere but the SCXML namespace is rejected at
    # lowering with `{:foreign_element, "scxml", uri}` before a `%Document{}`
    # ever exists. check_namespace/1's non-nil
    # branch and its span precedence are therefore only reachable by
    # constructing the `%Document{}` directly, which is what this test does:
    # it lowers a normal, fully-boilerplated document (so `attribute_locations[:xmlns]`
    # carries a real value span) and then overwrites `namespace` to simulate
    # a resolved-but-wrong URI, the shape check_namespace/1's type signature
    # allows for even though today's lowering can never actually produce it.
    #
    # sabotage: `check_namespace/1` falls back to `document.location` even
    # when `attribute_locations[:xmlns]` exists (e.g. by calling
    # `span(document, :location)` unconditionally) -> the reported span
    # moves off the `xmlns` value (line 2) onto the `<scxml>` start tag
    # (line 1), reddening this assertion
    test "a document whose resolved namespace is wrong is reported at the xmlns value span" do
      xml = """
      <scxml
          xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
      </scxml>
      """

      document = %{lower!(xml) | namespace: "http://example.com/other"}

      assert {:error, [%Error{reason: {:bad_namespace, "http://example.com/other"}} = error],
              _warnings} =
               Validator.validate(document, xml)

      assert error.location.start_line == 2
    end

    # sabotage: `check_version/1` tests presence (`version != nil`) instead
    # of equality to `"1.0"`, mirroring v1's regex-based check -> a written
    # `version="2.0"` is treated as present and therefore legal, reddening
    # this assertion
    test "version 2.0 is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="2.0">
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:bad_version, "2.0"}} = error], _warnings} = validate!(xml)
      assert error.message =~ "2.0"
    end
  end

  describe "check/2 - invoke_content_markup: true (ADR-0042)" do
    # sabotage: `check_namespace/2`'s `(relaxed? and is_nil(namespace))` arm
    # is dropped, leaving only `namespace == Namespace.scxml_namespace()` ->
    # a `nil` namespace stops passing even in flagged mode, and this
    # assertion reddens with a spurious `:bad_namespace` error.
    test "a boilerplate-free fragment passes clean when the flag is set" do
      xml = """
      <scxml version="1.0">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml, invoke_content_markup: true)
    end

    # sabotage: same mutation as above (`(relaxed? and is_nil(namespace))`
    # dropped from `check_namespace/2`) -> `document.namespace` is `nil`
    # here too, so this assertion reddens the same way.
    test "a fragment reports only bad_version when the flag is set and version is wrong" do
      xml = """
      <scxml version="2.0">
          <state id="a"/>
      </scxml>
      """

      assert {:error, [error], _warnings} = validate!(xml, invoke_content_markup: true)
      assert %Error{reason: {:bad_version, "2.0"}} = error
    end

    # A non-nil namespace that is not the SCXML URI must keep failing in
    # flagged mode too - the flag only ever widens the `nil` case. This
    # constructs the same not-otherwise-reachable shape the unflagged
    # "resolved namespace is wrong" test above does, since lowering itself
    # never produces a resolved-but-wrong namespace through the normal
    # pipeline.
    #
    # sabotage: `check_namespace/2`'s guard is changed from
    # `namespace == Namespace.scxml_namespace() or (relaxed? and
    # is_nil(namespace))` to `relaxed? or namespace ==
    # Namespace.scxml_namespace()` (the flag alone short-circuits the check)
    # -> a wrong, non-nil namespace now passes clean in flagged mode, and
    # this assertion's `{:error, [...]}` match reddens with `{:ok, ...}`.
    test "a wrong, non-nil namespace still fails when the flag is set" do
      xml = """
      <scxml
          xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
      </scxml>
      """

      document = %{lower!(xml) | namespace: "http://example.com/other"}

      assert {:error, [%Error{reason: {:bad_namespace, "http://example.com/other"}}], _warnings} =
               Validator.validate(document, xml, invoke_content_markup: true)
    end
  end

  defp find(errors, code) do
    Enum.find(errors, fn error -> Error.code(error.reason) == code end)
  end
end
