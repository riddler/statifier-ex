defmodule Statifier.Invoke.SourceTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Source
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp invoke_content(machine, state_name) do
    {:ok, index} = Machine.index(machine, state_name)
    [minvoke] = elem(machine.states, index).invoke
    {:static, markup} = minvoke.content
    markup
  end

  defp invoke(fields) do
    struct!(
      Invoke,
      Keyword.merge(
        [invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1],
        fields
      )
    )
  end

  @child_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s1" version="1.0" datamodel="predicator">
      <final id="s1" />
  </scxml>
  """

  describe "resolve/2" do
    # sabotage: the `content is a binary` success clause's `{:ok, machine} ->
    # {:ok, machine}` branch is changed to `{:ok, _machine} -> {:error,
    # :sabotage}` -> the `{:ok, %Machine{}}` match below reddens
    test "content is a binary -> Statifier.compile/1, success" do
      assert {:ok, %Machine{}} = Source.resolve(invoke(content: @child_xml), [])
    end

    # sabotage: `resolve/2`'s `content is a binary` clause's `{:error, errors}`
    # branch is changed to `{:error, {:content_not_markup, errors}}` (wrong
    # tag) -> the assertion on `{:compile, [_ | _]}` below reddens
    test "content is a binary -> Statifier.compile/1, failure folds to {:compile, errors}" do
      assert {:error, {:compile, [_error | _rest]}} =
               Source.resolve(invoke(content: "<not-scxml/>"), [])
    end

    # sabotage: the `content is nil, src is a binary, opts[:invoke_source] is
    # a fun` clause's `resolver.(src)` call is changed to `resolver.("wrong")`
    # -> the resolver is called with the wrong argument, and the assertion
    # that the resolver received the original `src` reddens
    test "content is nil, src is a binary, opts[:invoke_source] is a fun -> fun.(src)" do
      test_pid = self()

      resolver = fn src ->
        send(test_pid, {:resolved, src})
        Statifier.compile(@child_xml)
      end

      assert {:ok, %Machine{}} =
               Source.resolve(invoke(content: nil, src: "file:child.scxml"),
                 invoke_source: resolver
               )

      assert_received {:resolved, "file:child.scxml"}
    end

    # sabotage: the resolver-branch clause wraps the resolver's return in an
    # extra `{:ok, _}` (`{:ok, resolver.(src)}` instead of `resolver.(src)`)
    # -> this assertion reddens (`{:ok, {:error, :boom}}` instead of
    # `{:error, :boom}`)
    test "content is nil, src is a binary, opts[:invoke_source] returns {:error, _} unchanged" do
      resolver = fn _src -> {:error, :boom} end

      assert {:error, :boom} =
               Source.resolve(invoke(content: nil, src: "file:child.scxml"),
                 invoke_source: resolver
               )
    end

    # sabotage: the `no resolver` branch is changed from
    # `{:error, :src_not_resolved}` to `{:ok, nil}` -> this assertion reddens
    test "content is nil, src is a binary, no resolver -> {:error, :src_not_resolved}" do
      assert {:error, :src_not_resolved} =
               Source.resolve(invoke(content: nil, src: "file:x.scxml"), [])
    end

    # sabotage: the `content_not_markup` clause's guard `not is_nil(content)`
    # is dropped, so this clause also matches a `nil` content and the
    # `:no_source` test below reddens (it now returns `{:content_not_markup,
    # nil}` instead of `{:error, :no_source}`)
    test "content is neither nil nor a binary -> {:error, {:content_not_markup, content}}" do
      assert {:error, {:content_not_markup, %{a: 1}}} =
               Source.resolve(invoke(content: %{a: 1}), [])
    end

    # sabotage: the `src`-checking clause is reordered ahead of the
    # `content`-checking clause -> a `src` with no `invoke_source` configured
    # now wins over a compilable `content`, and this assertion reddens
    # (`{:error, :src_not_resolved}` instead of `{:ok, %Machine{}}`)
    test "content wins over src when both are present" do
      assert {:ok, %Machine{}} =
               Source.resolve(invoke(content: @child_xml, src: "file:ignored.scxml"), [])
    end

    # sabotage: the final clause's `{:error, :no_source}` is changed to
    # `{:error, :src_not_resolved}` -> this assertion reddens
    test "neither src nor content -> {:error, :no_source}" do
      assert {:error, :no_source} = Source.resolve(invoke(content: nil, src: nil), [])
    end
  end

  # ADR-0041: `<invoke><content><scxml>...</scxml></content></invoke>` -
  # markup lowers to a source slice at compile time (`Statifier.Compiler`),
  # and this module is the existing binary path (ADR-0038) that resolves
  # that slice into a child `Machine.t()` at invoke time.
  describe "resolve/2 - inline <content> markup (ADR-0041)" do
    @test220_shaped_xml """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <state id="s0">
            <onentry>
                <send event="timeout" delay="5s" />
            </onentry>
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="subFinal" version="1.0" datamodel="predicator">
                        <final id="subFinal" />
                    </scxml>
                </content>
            </invoke>
            <transition event="done.invoke" target="pass" />
            <transition event="*" target="fail" />
        </state>
        <final id="pass">
            <onentry>
                <log label="Outcome" expr="'pass'" />
            </onentry>
        </final>
        <final id="fail">
            <onentry>
                <log label="Outcome" expr="'fail'" />
            </onentry>
        </final>
    </scxml>
    """

    # sabotage: the `content is a binary` success clause's `{:ok, machine} ->
    # {:ok, machine}` branch is changed to `{:ok, _machine} -> {:error,
    # :sabotage}` (the same mutation the first `resolve/2` test above uses) ->
    # this assertion reddens too, since it exercises the same clause with a
    # markup slice produced by the compiler instead of a hand-written binary.
    #
    # The inner `<scxml>` here carries its own `xmlns` (unlike the actual
    # corpus test220_test.exs:26-31, which does not); `Statifier.compile/1`
    # on the extracted markup runs the same
    # `Statifier.Validator.Checks.Boilerplate` check any standalone document
    # does, and that check requires `document.namespace` to resolve to the
    # SCXML namespace, not merely `nil` - the relaxed rule only reaches as
    # far as `Statifier.Lowering.lower/2` (see the next test), so a bare
    # `<scxml>` root still fails to compile standalone, xmlns-less-corpus-file
    # or not. That gap is pre-existing and outside ADR-0041's scope.
    test "an Effect.Invoke.content, test220-shaped and namespaced, resolves to a child Machine" do
      markup = @test220_shaped_xml |> compile!() |> invoke_content("s0")

      assert {:ok, %Machine{}} = Source.resolve(invoke(content: markup), [])
    end

    @no_namespace_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml initial="s1" version="1.0">
                        <final id="s1" />
                    </scxml>
                </content>
            </invoke>
        </state>
    </scxml>
    """

    # This fragment's root has no `xmlns` at all (test220's own shape).
    # `Statifier.Compiler.build_content_expr/2`'s markup arm folds it exactly
    # as any other markup; the relaxed rule
    # (`Statifier.Lowering.Namespace.scxml_vocabulary?/1` accepting `nil`)
    # means `Statifier.Lowering.lower/2` dispatches every element in the
    # fragment as SCXML vocabulary rather than rejecting it as foreign -
    # `Statifier.compile/1`'s failure here is `Checks.Boilerplate`'s
    # separate, pre-existing root-declaration requirement (see the comment
    # on the test above), never a `{:foreign_element, ...}` or
    # `{:unexpected_root, ...}` lowering error. This is the precise, testable
    # form of "relaxed no-namespace rule" available at this boundary today.
    #
    # sabotage: `Statifier.Lowering.Namespace.scxml_vocabulary?/1`'s
    # `uri in [nil, @scxml_namespace]` is changed to `uri in [@scxml_namespace]`
    # (dropping the relaxed no-namespace rule) -> lowering now rejects the
    # fragment's `<final>` child as foreign before ever reaching
    # `Checks.Boilerplate`, and the refutation below (no lowering-shaped
    # error in the list) reddens.
    test "a <content> fragment with no namespace declaration lowers as SCXML vocabulary (G.6)" do
      markup = @no_namespace_document |> compile!() |> invoke_content("s0")

      assert {:error, {:compile, errors}} = Source.resolve(invoke(content: markup), [])

      refute Enum.any?(errors, fn
               %{reason: {:foreign_element, _name, _uri}} -> true
               %{reason: {:unexpected_root, _name}} -> true
               _other -> false
             end)
    end

    @non_scxml_root_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="http://www.w3.org/TR/scxml/">
                <content><not-scxml/></content>
            </invoke>
        </state>
    </scxml>
    """

    # sabotage: `Source.resolve/2`'s `content is a binary` clause's
    # `{:error, errors} -> {:error, {:compile, errors}}` branch is changed to
    # `{:error, errors} -> {:error, errors}` (dropping the `:compile` tag) ->
    # this assertion's `{:error, {:compile, [_ | _]}}` pattern reddens.
    test "a <content> with a non-<scxml> root compiles at parent time, fails only at resolve time" do
      machine = compile!(@non_scxml_root_document)
      markup = invoke_content(machine, "s0")

      assert {:error, {:compile, [_error | _rest]}} = Source.resolve(invoke(content: markup), [])
    end

    @truncated_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="http://www.w3.org/TR/scxml/">
                <content><![CDATA[<scxml version="1.0"><final id="s1">]]></content>
            </invoke>
        </state>
    </scxml>
    """

    # sabotage: same mutation as the non-<scxml>-root test above (the
    # `:compile` tag dropped from `Source.resolve/2`'s error branch) ->
    # this assertion reddens for the same reason.
    test "a <content> with a truncated fragment compiles at parent time, fails only at resolve time" do
      machine = compile!(@truncated_document)
      markup = invoke_content(machine, "s0")

      assert {:error, {:compile, [_error | _rest]}} = Source.resolve(invoke(content: markup), [])
    end

    # This pins ADR-0041's accepted namespace limitation as tested behavior,
    # so a future change to it is visible; it is an assertion about the
    # limitation, not a fix for it. The slice drops namespace declarations
    # made on ancestors (`xmlns:ex` is declared on the parent `<scxml>`, not
    # inside the sliced fragment), so the fragment's `ex`-prefixed root can
    # never resolve at invoke time.
    @ancestor_prefix_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" xmlns:ex="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="http://www.w3.org/TR/scxml/">
                <content><ex:scxml initial="subFinal" version="1.0"><ex:final id="subFinal"/></ex:scxml></content>
            </invoke>
        </state>
    </scxml>
    """

    # sabotage: `Source.resolve/2`'s `content is a binary` clause's
    # `{:error, errors} -> {:error, {:compile, errors}}` branch is changed to
    # `{:error, errors} -> {:error, errors}` (the same mutation the
    # non-`<scxml>`-root and truncated-fragment tests above use) -> this
    # assertion's `{:error, {:compile, [_ | _]}}` pattern reddens too. The
    # `ex` prefix, undeclared inside the slice, resolves to `nil`
    # (`Statifier.Lowering.Namespace.resolve/2`'s own leniency for an
    # unresolved prefix) - the relaxed rule then accepts that `nil` as SCXML
    # vocabulary and lowering succeeds, so this fails for the same reason the
    # "no namespace declaration" test above does
    # (`Checks.Boilerplate`'s `{:bad_namespace, nil}`), not a parser-level
    # undefined-prefix error.
    test "a fragment root using an ancestor-declared prefix fails at resolve time" do
      machine = compile!(@ancestor_prefix_document)
      markup = invoke_content(machine, "s0")

      assert {:error, {:compile, [_error | _rest]}} = Source.resolve(invoke(content: markup), [])
    end

    @nested_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="http://www.w3.org/TR/scxml/">
                <content>
                    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="i0" version="1.0">
                        <state id="i0">
                            <invoke type="http://www.w3.org/TR/scxml/">
                                <content>
                                    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="f0" version="1.0">
                                        <final id="f0" />
                                    </scxml>
                                </content>
                            </invoke>
                        </state>
                    </scxml>
                </content>
            </invoke>
        </state>
    </scxml>
    """

    # sabotage: same mutation as this describe block's first test (the
    # `{:ok, machine} -> {:ok, machine}` clause changed to
    # `{:ok, _machine} -> {:error, :sabotage}`) -> this assertion reddens too,
    # since resolving the outer invoke's markup still runs through the same
    # `Statifier.compile/1` call, one session boundary at a time (no re-entrant
    # parse of the inner `<invoke><content>` - that only compiles when its own
    # invoke fires inside the child session).
    test "a child document that itself contains <invoke><content> compiles" do
      markup = @nested_document |> compile!() |> invoke_content("s0")

      assert {:ok, %Machine{}} = Source.resolve(invoke(content: markup), [])
    end
  end
end
