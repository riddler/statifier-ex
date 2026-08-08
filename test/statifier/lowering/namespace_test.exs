defmodule Statifier.Lowering.NamespaceTest do
  use ExUnit.Case, async: true

  alias Statifier.Document
  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower()
    document
  end

  describe "lower/1 - prefixed documents, the m0_test.exs shape" do
    # sabotage: `Lowering.lower/1` dispatches on the raw `name` instead of the
    # resolved `local_name` (drops resolve-before-dispatch for the root) ->
    # `<ns0:scxml>` misses the dispatch map and this test reddens with
    # `{:unexpected_root, "ns0:scxml"}` instead of a matching tree
    test "every element ns0:-prefixed lowers to the same tree as its unprefixed twin" do
      prefixed = """
      <ns0:scxml xmlns:ns0="http://www.w3.org/2005/07/scxml" name="root">
        <ns0:state id="A">
          <ns0:onentry>
            <ns0:log expr="&quot;entering A&quot;"/>
          </ns0:onentry>
          <ns0:transition target="B" event="e1"/>
        </ns0:state>
        <ns0:state id="B"/>
      </ns0:scxml>
      """

      unprefixed = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" name="root">
        <state id="A">
          <onentry>
            <log expr="&quot;entering A&quot;"/>
          </onentry>
          <transition target="B" event="e1"/>
        </state>
        <state id="B"/>
      </scxml>
      """

      prefixed_doc = lower!(prefixed)
      unprefixed_doc = lower!(unprefixed)

      strip_locations = fn document -> strip(document) end

      assert strip_locations.(prefixed_doc) == strip_locations.(unprefixed_doc)
    end
  end

  describe "lower/1 - no xmlns at all" do
    # sabotage: the SCXML-namespace check in `Lowering.lower/1` is changed
    # from `uri in [nil, Namespace.scxml_namespace()]` to
    # `uri == Namespace.scxml_namespace()`, rejecting the lenient `nil` case
    # -> this test reddens with a `{:foreign_element, ...}` error instead of
    # `{:ok, _}`
    test "a fixture with no xmlns declared anywhere still lowers" do
      xml = """
      <scxml name="root">
        <state id="A"/>
      </scxml>
      """

      assert %Document{states: [%State{id: "A"}]} = lower!(xml)
    end
  end

  describe "lower/1 - a genuinely foreign namespace" do
    # sabotage: `Lowering.walk_child/4`'s dispatch guard is widened from
    # `uri in [nil, Namespace.scxml_namespace()]` to `true`, accepting any
    # URI -> this test reddens because `<html:div>` falls through to
    # `{:unsupported_element, "html:div"}` instead of `{:foreign_element, ...}`
    test "an element bound to a non-SCXML namespace errors, naming the URI" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" name="root">
        <html:div xmlns:html="http://www.w3.org/1999/xhtml"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:foreign_element, "html:div", uri}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert uri == "http://www.w3.org/1999/xhtml"
      assert error.location != nil
    end

    # sabotage: `Lowering.lower/1`'s dispatch guard (the root-level one) is
    # widened from `uri in [nil, Namespace.scxml_namespace()]` to `true` ->
    # this test reddens because `<ns0:state>` (the child, resolved against the
    # same foreign `ns0` binding) dispatches and builds instead of the root
    # itself reporting `{:foreign_element, "ns0:scxml", ...}`
    test "a prefix declared but bound to a non-SCXML URI errors rather than dispatching" do
      xml = """
      <ns0:scxml xmlns:ns0="http://example.com/not-scxml" name="root">
        <ns0:state id="A"/>
      </ns0:scxml>
      """

      assert {:error, [%Error{reason: {:foreign_element, "ns0:scxml", uri}}]} =
               xml |> parse!() |> Lowering.lower()

      assert uri == "http://example.com/not-scxml"
    end
  end

  describe "lower/1 - subtree-local scoping" do
    # sabotage: `Namespace.push/2` accumulates declarations into a scope
    # shared across the whole walk (via the process dictionary) instead of
    # returning a fresh scope per element -> `<state id="B">`'s `foo:widget`
    # child now sees `<state id="A">`'s `xmlns:foo` declaration leaking in,
    # and this test reddens on the second assertion,
    # `{:unsupported_element, "foo:widget"}`, which observes
    # `{:foreign_element, "foo:widget", ...}` instead
    test "a declaration on a nested element applies only to its own subtree" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" name="root">
        <state id="A" xmlns:foo="http://example.com/foo">
          <foo:widget/>
        </state>
        <state id="B">
          <foo:widget/>
        </state>
      </scxml>
      """

      assert {:error, errors} = xml |> parse!() |> Lowering.lower()

      # Inside <state id="A">, foo: resolves against foo's own declaration -
      # a genuinely foreign element bound to http://example.com/foo.
      assert %Error{reason: {:foreign_element, "foo:widget", "http://example.com/foo"}} =
               Enum.at(errors, 0)

      # Inside <state id="B">, the sibling's foo: declaration is out of
      # scope, so the prefix is undeclared here (uri: nil) - lenient, so it
      # dispatches on the local name "widget", which is not a known SCXML
      # element and misses the dispatch map.
      assert %Error{reason: {:unsupported_element, "foo:widget"}} = Enum.at(errors, 1)
    end
  end

  defp strip(%Document{} = document) do
    %{
      initial: document.initial,
      name: document.name,
      datamodel: document.datamodel,
      binding: document.binding,
      version: document.version,
      states: Enum.map(document.states, &strip/1)
    }
  end

  defp strip(%State{} = state) do
    %{
      kind: state.kind,
      id: state.id,
      initial: state.initial,
      states: Enum.map(state.states, &strip/1),
      transitions: Enum.map(state.transitions, &strip/1),
      onentry: Enum.map(state.onentry, &strip/1),
      onexit: Enum.map(state.onexit, &strip/1)
    }
  end

  defp strip(%Statifier.Document.Transition{} = transition) do
    %{
      event: transition.event,
      target: transition.target,
      cond: transition.cond,
      type: transition.type,
      content: Enum.map(transition.content, &strip/1)
    }
  end

  defp strip(%Statifier.Document.Block{} = block) do
    %{content: Enum.map(block.content, &strip/1)}
  end

  defp strip(%Statifier.Document.Log{} = log) do
    %{label: log.label, expr: log.expr}
  end

  defp strip(%Statifier.Document.Raise{} = raise_node) do
    %{event: raise_node.event}
  end
end
