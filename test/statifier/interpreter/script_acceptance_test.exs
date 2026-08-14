defmodule Statifier.Interpreter.ScriptAcceptanceTest do
  use ExUnit.Case, async: true

  # End-to-end coverage for `<script>` as executable content, through the
  # real pipeline (`Statifier.compile/1`, `Statifier.initialize/2`,
  # `Statifier.send_event/2`) rather than a hand-substituted node: every
  # place spec 5.8 allows a `<script>` as executable content, in one
  # document - `<onentry>`, `<onexit>`, a transition, an `<if>` branch, and
  # a `<foreach>` body. `Statifier.Interpreter.ContentTest`'s "<script>,
  # through the real block runner" describe already exercises the
  # block-runner-level detail (document order, mid-program failure,
  # deferred parse failure); this file's job is proving all five placements
  # actually reach the block runner through the full compiled pipeline.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <datamodel>
          <data id="a" expr="0"/>
          <data id="b" expr="0"/>
          <data id="c" expr="0"/>
          <data id="d" expr="0"/>
          <data id="e" expr="0"/>
      </datamodel>
      <state id="s1">
          <onentry>
              <script>a = 1;</script>
          </onentry>
          <onexit>
              <script>b = 1;</script>
          </onexit>
          <transition event="go" target="s2">
              <script>c = 1;</script>
          </transition>
      </state>
      <state id="s2">
          <onentry>
              <if cond="true">
                  <script>d = 1;</script>
              </if>
              <foreach array="[1, 2, 3]" item="i">
                  <script>e = e + i;</script>
              </foreach>
          </onentry>
      </state>
  </scxml>
  """

  defp machine do
    {:ok, machine} = Statifier.compile(@document)
    machine
  end

  # sabotage: `Statifier.Compiler.build_content_node/2`'s `%DScript{}` clause
  # is deleted (no compiler clause for `%Document.Script{}`) -> this document
  # no longer compiles to a `%Machine{}` at all, reddening the `{:ok, _}`
  # match `machine/0` relies on before this test's own assertion ever runs.
  test "<onentry>'s <script> runs on entry to the initial state" do
    {ms, _effects} = Statifier.initialize(machine())

    assert ms.datamodel["a"] == 1
    assert ms.datamodel["b"] == 0
  end

  # sabotage: `place/3`'s `%Script{}` clause (the `%Block{}`/`%Transition{}`/
  # `%If{}`/`%Foreach{}` generic `{:content_node, node}` clauses already
  # handle a `<script>` correctly for every parent but the top level - see
  # `content_test.exs`'s own top-level tests for that specific clause) is
  # covered structurally by `lower/1` succeeding at all for this document;
  # this test's own reddening mutation is `Statifier.Machine.Content.Script`'s
  # `execute/2` returning `{:ok, context, []}` without ever calling
  # `Statifier.Evaluator.execute/2` -> `b`/`c`/`d`/`e` would all stay `0`
  # after the transition fires, reddening every assertion below at once.
  test "<onexit>, a transition's own content, an <if> branch, and a <foreach> body all run their <script>s" do
    {ms, _effects} = Statifier.initialize(machine())
    assert {:ok, next, _effects} = Statifier.send_event(ms, "go")

    assert next.datamodel["b"] == 1
    assert next.datamodel["c"] == 1
    assert next.datamodel["d"] == 1
    assert next.datamodel["e"] == 6
    assert Statifier.active_leaf_states(next) == MapSet.new(["s2"])
  end
end
