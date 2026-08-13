defmodule Statifier.Compiler.DataTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Compiler.Error
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Data, as: MData
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  defp state_of(machine, name), do: elem(machine.states, idx(machine, name))

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <datamodel>
          <data id="Root1" expr="1 + 1"/>
          <data id="Root2"/>
      </datamodel>
      <state id="s0">
          <datamodel>
              <data id="Local1" expr="2 + 2"/>
              <data id="Local2" src="somefile.json"/>
              <data id="Local3">[1, 2, 3]</data>
              <data id="Local4">hello</data>
          </datamodel>
      </state>
  </scxml>
  """

  # sabotage: in Statifier.Compiler.assign_data/3, change `d_index = acc.d_next`
  # to `d_index = acc.d_next + 1` -> the first d_index assigned becomes 1
  # instead of 0, and the density assertion below goes red.
  test "d_index is dense and ascending from 0, document order" do
    machine = compile!(@document)

    d_indexes = for d <- Tuple.to_list(machine.data_elements), do: d.d_index

    assert d_indexes == Enum.to_list(0..(length(d_indexes) - 1))

    ids = for d <- Tuple.to_list(machine.data_elements), do: d.id
    assert ids == ["Root1", "Root2", "Local1", "Local2", "Local3", "Local4"]
  end

  # sabotage: in Statifier.Compiler.compile/1, drop the `assign_data(document.datamodel_element, 0, acc0)`
  # call made before `walk_siblings/4` -> the root's own top-level <data>
  # never get assigned a d_index, so this test's membership assertion goes
  # red (root.data becomes []).
  test "top-level <data> land on the root state's own data list, preceding every state-scoped one" do
    machine = compile!(@document)
    root = elem(machine.states, 0)

    assert root.data == [0, 1]

    s0 = state_of(machine, "s0")
    assert s0.data == [2, 3, 4, 5]
  end

  # sabotage: in Statifier.Compiler.build_data_value/2, swap the {:ok, compiled}
  # clause's return for a hardcoded {:static, nil} -> a successfully-compiled
  # expr never becomes a {:compiled, ...} value, and this test goes red.
  test "expr compiles to the compiled expr() arm" do
    machine = compile!(@document)
    root = elem(machine.states, 0)
    [root1_index | _rest] = root.data

    assert %MData{id: "Root1", value: {:compiled, %Predicator.Compiled{}, "1 + 1"}} =
             Machine.data(machine, root1_index)
  end

  # sabotage: in Statifier.Compiler.build_data_value/2's expr clause, change
  # `{:error, error} -> {{:invalid, error}, location}` to always return
  # `{Expressions.static(nil), location}` -> a malformed expr silently
  # becomes a static nil instead of {:invalid, _}, and this test goes red.
  test "a malformed expr compiles to {:invalid, error} and Compiler.compile/1 still returns {:ok, machine}" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <datamodel>
            <data id="o1" expr="{p1: 'v1'"/>
        </datamodel>
        <state id="s0"/>
    </scxml>
    """

    machine = compile!(xml)

    assert %MData{id: "o1", value: {:invalid, %Error{}}} = Machine.data(machine, 0)
  end

  # sabotage: in Statifier.Compiler.Expressions.inline_value/1, drop the
  # compile-time evaluate step (`with ... {:ok, value} <- Predicator.evaluate(...)`)
  # and always fall through to `{:static, trimmed}` -> `[1, 2, 3]` folds to
  # the string "[1, 2, 3]" instead of the list, and this test goes red.
  test "[1, 2, 3] child text folds to the list, not a load" do
    machine = compile!(@document)
    s0 = state_of(machine, "s0")
    [_local1, _local2, local3_index, _local4] = s0.data

    assert %MData{id: "Local3", value: {:static, [1, 2, 3]}} = Machine.data(machine, local3_index)
  end

  # sabotage: in Statifier.Compiler.Expressions.inline_value/1, change the
  # fallback clause's `{:static, trimmed}` to `{:static, nil}` -> `hello`
  # (an identifier that fails to evaluate against the empty context) folds
  # to a static nil instead of the string literal, and this test goes red.
  test "hello child text folds to the static string, not a datamodel load" do
    machine = compile!(@document)
    s0 = state_of(machine, "s0")
    [_local1, _local2, _local3, local4_index] = s0.data

    assert %MData{id: "Local4", value: {:static, "hello"}} = Machine.data(machine, local4_index)
  end

  # sabotage: in Statifier.Compiler.build_data_value/2's src clause, change
  # `{{:src, src}, ...}` to `{{:static, src}, ...}` -> a <data src="..."/>
  # compiles to a plain static string instead of the {:src, uri} arm, and
  # this test goes red.
  test "src becomes {:src, uri}" do
    machine = compile!(@document)
    s0 = state_of(machine, "s0")
    [_local1, local2_index | _rest] = s0.data

    assert %MData{id: "Local2", value: {:src, "somefile.json"}} =
             Machine.data(machine, local2_index)
  end

  # sabotage: in Statifier.Compiler.build_data_value/2's blank-text clause
  # (a bare <data> lowers to `text: ""`, not `nil`, so this clause is the
  # one actually exercised, not the final no-value-source fallback), change
  # `{Expressions.static(nil), ...}` to `{Expressions.static(""), ...}` ->
  # a bare <data id="x"/> stops compiling to {:static, nil}, and this test
  # goes red.
  test "a bare <data id=\"x\"/> becomes {:static, nil}" do
    machine = compile!(@document)
    root = elem(machine.states, 0)
    [_root1, root2_index] = root.data

    assert %MData{id: "Root2", value: {:static, nil}} = Machine.data(machine, root2_index)
  end

  # sabotage: in Statifier.Compiler.compile/1, extend the `errors` fold to
  # also collect every compiled %MData{value: {:invalid, error}}'s error
  # into the merge -> a bad <data expr> starts contributing its own error
  # alongside the bad cond's (and, per the sibling test above, a lone bad
  # <data expr> starts failing compile/1 outright), so both this test's
  # `[error]` match and the sibling's `{:ok, machine}` match go red.
  test "a bad cond and a bad <data expr> report exactly one error - the cond's" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <datamodel>
            <data id="o1" expr="{p1: 'v1'"/>
        </datamodel>
        <state id="s0">
            <transition cond="1 &gt;" target="s0"/>
        </state>
    </scxml>
    """

    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)

    assert {:error, [error]} = Compiler.compile(document)

    assert {:expression_compile_error, {:transition, _t_index}, "1 >", _parse_error} =
             error.reason
  end
end
