defmodule Statifier.Compiler.FunctionCallsTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler.Error

  # Every expression below calls a function no context holds, nested in
  # another call's arguments or under a dotted (namespaced) name, and the
  # chart spreads them over six elements: a `<data expr>`, a top-level
  # `<script>`, an `<assign expr>`, a `<log expr>`, a transition `cond` and
  # a `<send>` `<param expr>`. `In` and `len` are known and never reported.
  # The expected list is the answer the check gave before it read calls
  # through `Predicator.Analysis`, recorded as it stood: a top-level
  # `<script>` and an `<assign>` carry `node_location` rather than
  # `location`, so their calls report at the `<scxml>` element (line 1).
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <datamodel>
          <data id="x" expr="alpha(beta(1))"/>
      </datamodel>
      <script>y = ns.load(gamma(2)); z = ns.load(3)</script>
      <state id="a">
          <onentry>
              <assign location="x" expr="len(delta(ns.pick(1), 2))"/>
              <log expr="omega(1) + alpha(2)"/>
          </onentry>
          <transition event="e" cond="In('a') and outer.fn(inner(1)) > 0" target="b"/>
      </state>
      <state id="b">
          <onentry>
              <send event="s"><param name="p" expr="ns.deep.call(beta(1))"/></send>
          </onentry>
      </state>
  </scxml>
  """

  describe "check/2, through Statifier.compile/2" do
    # sabotage: `calls/1` in function_calls.ex keeps only the first call
    # `Predicator.Analysis.calls/1` lists (`Enum.take(calls, 1)`) -> every
    # nested call goes unreported and the list goes red
    test "reports nested and namespaced calls by name, element and order" do
      assert {:error, errors} = Statifier.compile(@chart)

      reported =
        Enum.map(errors, fn %Error{reason: {:unknown_function, name, source}} = error ->
          {name, source, error.location.start_line}
        end)

      assert reported == [
               {"delta", "len(delta(ns.pick(1), 2))", 1},
               {"gamma", "y = ns.load(gamma(2)); z = ns.load(3)", 1},
               {"ns.load", "y = ns.load(gamma(2)); z = ns.load(3)", 1},
               {"ns.pick", "len(delta(ns.pick(1), 2))", 1},
               {"alpha", "alpha(beta(1))", 3},
               {"beta", "alpha(beta(1))", 3},
               {"alpha", "omega(1) + alpha(2)", 9},
               {"omega", "omega(1) + alpha(2)", 9},
               {"inner", "In('a') and outer.fn(inner(1)) > 0", 11},
               {"outer.fn", "In('a') and outer.fn(inner(1)) > 0", 11},
               {"beta", "ns.deep.call(beta(1))", 15},
               {"ns.deep.call", "ns.deep.call(beta(1))", 15}
             ]

      offsets = Enum.map(errors, & &1.location.start_offset)
      assert offsets == Enum.sort(offsets)
    end
  end
end
