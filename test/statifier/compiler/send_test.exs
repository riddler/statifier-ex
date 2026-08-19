defmodule Statifier.Compiler.SendTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Machine, Parser, Validator}
  alias Statifier.Compiler.Error
  alias Statifier.Machine.Content.Send, as: MSend
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

  # `s0`'s `onentry` carries the one `<send>`: a well-formed `foo` entry
  # alongside the malformed `"foo` entry (four characters, an opening quote
  # with no closing quote - test553's own fixture), so the deferral is pinned
  # as per-entry, not per-attribute.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <onentry>
              <send event="e" namelist="foo &quot;foo"/>
          </onentry>
      </state>
  </scxml>
  """

  defp send_node(machine) do
    [block] = state_of(machine, "s0").onentry
    [c_index] = block.content
    Machine.content(machine, c_index)
  end

  # sabotage: in Statifier.Compiler.build_namelist_param/5, change the
  # `{:error, error} -> {:invalid, error}` clause to `{:error, _error} ->
  # Expressions.static(nil)` -> the malformed entry's expr silently becomes
  # {:static, nil} instead of {:invalid, %Error{}}, and this test goes red.
  test "a malformed namelist entry compiles to {:invalid, error} and Compiler.compile/1 still returns {:ok, machine}" do
    machine = compile!(@document)

    assert %MSend{namelist: [good, bad]} = send_node(machine)

    assert %MParam{name: "foo", kind: :location, expr: {:compiled, %Predicator.Compiled{}, "foo"}} =
             good

    assert %MParam{name: "\"foo", kind: :location, expr: {:invalid, %Error{}}} = bad
  end
end
