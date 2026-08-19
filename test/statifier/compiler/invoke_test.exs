defmodule Statifier.Compiler.InvokeTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Machine, Parser, Validator}
  alias Statifier.Compiler.Error
  alias Statifier.Machine.Invoke, as: MInvoke
  alias Statifier.Machine.Param, as: MParam

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  defp state_of(machine, name), do: elem(machine.states, idx(machine, name))

  # `inv1` exercises the static attribute forms (`type`, `src`) plus a
  # `<param>`; `inv2` exercises `typeexpr`, `idlocation`, `namelist`, a
  # compiled `<content expr>`, and a `<finalize>`; `inv3` exercises a
  # plain-text `<content>` with no `<finalize>` at all - the absent/empty
  # distinction 6.5 requires; `inv4` exercises `srcexpr` on its own (6.4.1
  # forbids `srcexpr` alongside a `<content>` child, so it cannot share
  # `inv2`'s).
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke id="inv1" type="http://example.com/static" src="http://example.com/src">
              <param name="p1" expr="1"/>
          </invoke>
          <invoke typeexpr="'dyn' + 'type'" idlocation="myid" namelist="a b">
              <content expr="1 + 1"/>
              <finalize>
                  <log label="finalized"/>
              </finalize>
          </invoke>
          <invoke type="t3">
              <content>payload</content>
          </invoke>
          <invoke type="t4" srcexpr="'dyn' + 'src'"/>
      </state>
  </scxml>
  """

  # sabotage: in `Statifier.Compiler.build_invoke_pair/6`, change the static
  # clause's `{Expressions.static(static_value), acc}` to
  # `{Expressions.static(nil), acc}` -> both assertions below (`inv1.type`
  # and `inv1.src`) go red, since the static attribute's own value is
  # dropped.
  test "a static `type`/`src` attribute lands as {:static, value}" do
    machine = compile!(@document)
    [inv1, _inv2, _inv3, _inv4] = state_of(machine, "s0").invoke

    assert %MInvoke{
             type: {:static, "http://example.com/static"},
             src: {:static, "http://example.com/src"}
           } = inv1
  end

  # sabotage: in `Statifier.Compiler.build_invoke_pair/6`, change the compile
  # clause's `case Expressions.compile(source, owner, location) do ... end`
  # to unconditionally `{nil, acc}` -> both `typeexpr`/`srcexpr`-compiled
  # assertions below go red.
  test "a `typeexpr`/`srcexpr` attribute compiles to {:compiled, ...}" do
    machine = compile!(@document)
    [_inv1, inv2, _inv3, inv4] = state_of(machine, "s0").invoke

    assert {:compiled, %Predicator.Compiled{}, "'dyn' + 'type'"} = inv2.type
    assert {:compiled, %Predicator.Compiled{}, "'dyn' + 'src'"} = inv4.src
  end

  # sabotage: in `Statifier.Compiler.build_namelist_param/5`, change the
  # `kind: :location` field to `kind: :expr` -> this test's `kind: :location`
  # assertion goes red.
  test "namelist entries compile to kind: :location params, in written order" do
    machine = compile!(@document)
    [_inv1, inv2, _inv3, _inv4] = state_of(machine, "s0").invoke

    assert [
             %MParam{name: "a", kind: :location, expr: {:compiled, %Predicator.Compiled{}, "a"}},
             %MParam{name: "b", kind: :location, expr: {:compiled, %Predicator.Compiled{}, "b"}}
           ] = inv2.namelist
  end

  # sabotage: in `Statifier.Compiler.build_invoke_content/3`, change the
  # `{:ok, expr} -> {expr, acc}` clause to unconditionally `{nil, acc}` ->
  # both assertions below (the compiled `<content expr>` and the static
  # `<content>` text) go red.
  test "<content> folds to {:compiled, ...} from expr, {:static, ...} from text" do
    machine = compile!(@document)
    [_inv1, inv2, inv3, _inv4] = state_of(machine, "s0").invoke

    assert {:compiled, %Predicator.Compiled{}, "1 + 1"} = inv2.content
    assert {:static, "payload"} = inv3.content
  end

  # sabotage: in `Statifier.Compiler.build_invoke_finalize/2`'s `%DBlock{}`
  # clause, change `{mblock, acc}` to `{%{mblock | content: []}, acc}` ->
  # the `<log>` child's compiled `c_index` is dropped from the block, and
  # this test's non-empty `content` assertion goes red.
  test "<finalize> compiles to a Machine.Block with a real c_index" do
    machine = compile!(@document)
    [_inv1, inv2, _inv3, _inv4] = state_of(machine, "s0").invoke

    assert %Statifier.Machine.Block{content: [c_index]} = inv2.finalize
    assert is_integer(c_index)
  end

  # sabotage: in `Statifier.Compiler.build_invoke_finalize/2`, change the
  # `nil` clause's `{nil, acc}` to `{:sabotage, acc}` -> this test's
  # `finalize: nil` assertion goes red even though `inv3` writes no
  # `<finalize>` child at all.
  test "an <invoke> with no <finalize> child compiles finalize: nil" do
    machine = compile!(@document)
    [_inv1, _inv2, inv3, _inv4] = state_of(machine, "s0").invoke

    assert %MInvoke{finalize: nil} = inv3
  end

  # sabotage: in `Statifier.Compiler.build_invoke_finalize/2`'s `%DBlock{}`
  # clause, replace the body with
  # `{%Statifier.Machine.Block{location: block.location, content: []}, acc}`,
  # skipping `assign_blocks/2` entirely -> the malformed `<log expr="1 +"/>`
  # below never enters `contents_acc`, so `build_contents/2` never sees it
  # and `Compiler.compile/1` returns `{:ok, _machine}` instead of
  # `{:error, _}`, reddening this test's `{:error, [error]}` assertion.
  test "a compile error inside <finalize> surfaces as a compiler error, not a crash" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0">
            <invoke type="t">
                <finalize>
                    <log expr="1 +"/>
                </finalize>
            </invoke>
        </state>
    </scxml>
    """

    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)

    assert {:error, [error]} = Compiler.compile(document)

    assert %Error{reason: {:expression_compile_error, {:content, _c_index}, "1 +", _parse_error}} =
             error
  end

  # test220's exact XML (test/scxml_tests/mandatory/invoke/test220_test.exs) -
  # the bead's acceptance shape: `<invoke><content><scxml>...</scxml></content></invoke>`.
  @test220_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
      <state id="s0">
          <onentry>
              <send event="timeout" delay="5s" />
          </onentry>
          <invoke type="http://www.w3.org/TR/scxml/">
              <content>
                  <scxml initial="subFinal" version="1.0" datamodel="predicator">
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

  # sabotage: `Statifier.Compiler.build_content_expr/2`'s markup clause
  # (`%DContent{expr: nil, markup: markup} when is_binary(markup)`) is
  # changed to build `Expressions.static(nil)` instead of
  # `Expressions.static(markup)` -> the `{:static, ^expected_markup}` match
  # below reddens because the invoke's content folds to `{:static, nil}`.
  test "test220's <invoke><content><scxml> compiles end to end, folding to {:static, markup}" do
    machine = compile!(@test220_xml)
    [invoke] = state_of(machine, "s0").invoke

    [expected_markup] =
      Regex.run(~r{<content>\s*(<scxml.*?</scxml>)\s*</content>}s, @test220_xml,
        capture: :all_but_first
      )

    assert {:static, ^expected_markup} = invoke.content
  end

  # test553/test554's shape (`namelist="&quot;foo"`, an unterminated string
  # literal): the document must still load, and the bad entry must survive
  # in `inv.namelist` rather than being dropped, so
  # `Interpreter.resolve_params/2` has something to intercept at execute
  # time (ADR-0031). A well-formed sibling entry compiles normally, pinning
  # that the deferral is per entry, not per attribute.
  @invalid_namelist_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <invoke type="t" namelist="&quot;foo good"/>
      </state>
  </scxml>
  """

  # sabotage: in `Statifier.Compiler.build_invoke_namelist/3`, restore
  # `Enum.reject(&is_nil/1)` around the mapped results and change
  # `build_namelist_param/5` to return `nil` on a compile failure -> the
  # invalid entry vanishes from `inv.namelist`, and this test's two-entry
  # presence assertion goes red.
  test "an invalid namelist entry compiles present, carrying {:invalid, error}" do
    machine = compile!(@invalid_namelist_document)
    [invoke] = state_of(machine, "s0").invoke

    assert [
             %MParam{name: "\"foo", kind: :location, expr: {:invalid, %Error{}}},
             %MParam{
               name: "good",
               kind: :location,
               expr: {:compiled, %Predicator.Compiled{}, "good"}
             }
           ] = invoke.namelist
  end
end
