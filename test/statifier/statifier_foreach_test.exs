defmodule Statifier.StatifierForeachTest do
  @moduledoc """
  Drives the eight corpus documents - seven W3C, one SCION - named under
  "Corpus/Ratchet Notes" in
  `docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md` through the real
  engine, end to end, without going through `Statifier.Case.test_scxml/4`.

  That was deliberate, not an oversight: until bead **st-af3.8**, all eight
  `foreach_elements` corpus files also tripped `conditional_transitions`
  (`test/support/feature_detector.ex`, then `:unsupported` - the
  `~r/\bcond\s*=/` attribute detector fires on `<transition cond=...>`
  everywhere these documents use it). `Statifier.Case.test_scxml/4` flunks
  rather than skips a document that names an unsupported feature
  (`test/support/case.ex:41-46`), so these eight flunked before that bead even
  though `<foreach>` itself was already fully implemented and correct.

  st-af3.8 flipped `conditional_transitions` to `:supported`, ran the full
  conformance suites, and ratcheted `test/passing_tests.json`
  (`mix test.baseline add`), so
  `test/scxml_tests/mandatory/foreach/test150_test.exs`, `test151_test.exs`,
  `test152_test.exs`, `test153_test.exs`, `test155_test.exs`,
  `test156_test.exs`, `test525_test.exs`, and
  `test/scion_tests/foreach/test1_test.exs` are now feature-clean and run
  through the generated harness too.

  This file is **not** a duplicate to delete now that that has landed: it drives the
  exact same documents through `Statifier.compile/1`, `Statifier.initialize/2`,
  `Statifier.send_event/2`, and `Statifier.active_leaf_states/1` - the same
  four-function public API `Statifier.Case`'s own private helpers use
  (`test/support/case.ex:16-21`) - and stays the only place in the suite that
  proves this behavior under a bare `mix test`, since the generated files stay
  tagged `:scion`/`:scxml_w3` and excluded from the default run
  (`test/test_helper.exs`). It remains valuable afterward as fast, always-on
  coverage of `<foreach>` that does not depend on the ratchet.

  Each XML fixture below is byte-identical to the corresponding generated
  corpus file's own heredoc - copied, not paraphrased, so this file proves the
  real document.

  SCION `foreach/test1` is included: it was run directly (not predicted) and
  passes as written, so it stays as the suite's only 0-based-`index` witness
  and the only document here exercising a second `<foreach>` with no `index`
  and raw ECMAScript-syntax `cond`s (`===`, `&&`).
  """

  use ExUnit.Case, async: true

  alias Statifier.MachineState

  # A top-level `<final>` terminates the interpreter (Appendix D's
  # `exit_interpreter`), which empties `MachineState.configuration` by
  # construction. The terminal position rides the `{:done, _}` effect instead
  # (`Statifier.Effect.Done.configuration`) - this mirrors
  # `Statifier.Case`'s own `observed_state_chart/2`
  # (`test/support/case.ex:145-152`), restoring it onto the `MachineState`
  # before reading leaves off it, rather than reimplementing the
  # index-to-id translation `Statifier.active_leaf_states/1` already owns.
  defp active_states(%MachineState{} = machine_state, effects) do
    machine_state =
      case Enum.find(effects, &match?({:done, _done}, &1)) do
        {:done, done} -> %{machine_state | configuration: done.configuration}
        nil -> machine_state
      end

    Statifier.active_leaf_states(machine_state)
  end

  defp compile!(xml) do
    case Statifier.compile(xml) do
      {:ok, machine} -> machine
      {:error, errors} -> flunk("Document did not compile: #{inspect(errors)}")
    end
  end

  # sabotage: tried `Statifier.Machine.Content.Foreach`'s `declare/2` with
  # `Map.put/3` instead of `Map.put_new/3` first, per the plan's primary
  # suggestion - it stayed green here (every `item`/`index` this corpus
  # declares is a genuinely new key in every document below, including
  # test152's two illegal-array/illegal-item cases, both of which fail
  # `check_iterable`/`check_name` *before* `declare/2` ever runs, so `put`
  # and `put_new` never diverge). Used the plan's named fallback instead:
  # re-evaluate `array` fresh every iteration (instead of once, before the
  # loop, in `execute/2`) -> test525's own `Var1` mutation becomes visible to
  # the iteration source, breaking the shallow-copy guarantee -> `Var2` never
  # reaches 3 by the time the stabilizing `Var2==3` transition is checked,
  # landing on "fail" instead of "pass" -> red (confirmed on both this file's
  # test525 and `test/statifier/machine/content/foreach_test.exs`'s existing
  # "mutating the array's own source variable inside the body does not change
  # the iteration count" leaf test).
  test "SCXML mandatory/foreach/test150 - item is declared when absent, and stays bound" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" />
            <data id="Var3">[1,2,3]</data>
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var1" index="Var2" array="Var3" />
                <raise event="foo" />
            </onentry>
            <transition event="error" target="fail" />
            <transition event="*" target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <foreach item="Var4" index="Var5" array="Var3" />
                <raise event="bar" />
            </onentry>
            <transition event="error" target="fail" />
            <transition event="*" target="s2" />
        </state>
        <state id="s2">
            <transition cond="Var4 !== undefined" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test151 - index is declared when absent, and stays bound" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" />
            <data id="Var2" />
            <data id="Var3">[1,2,3]</data>
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var1" index="Var2" array="Var3" />
                <raise event="foo" />
            </onentry>
            <transition event="error" target="fail" />
            <transition event="*" target="s1" />
        </state>
        <state id="s1">
            <onentry>
                <foreach item="Var4" index="Var5" array="Var3" />
                <raise event="bar" />
            </onentry>
            <transition event="error" target="fail" />
            <transition event="*" target="s2" />
        </state>
        <state id="s2">
            <transition cond="Var5 !== undefined" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test152 - illegal array or item halts the block before any iteration" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1" expr="0" />
            <data id="Var2" />
            <data id="Var3" />
            <data id="Var4" expr="7" />
            <data id="Var5">[1,2,3]</data>
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var2" index="Var3" array="Var4">
                    <assign location="Var1" expr="Var1 + 1" />
                </foreach>
                <raise event="foo" />
            </onentry>
            <transition event="error.execution" target="s1" />
            <transition event="*" target="fail" />
        </state>
        <state id="s1">
            <onentry>
                <foreach item="'continue'" index="Var3" array="Var5">
                    <assign location="Var1" expr="Var1 + 1" />
                </foreach>
                <raise event="bar" />
            </onentry>
            <transition event="error.execution" target="s2" />
            <transition event="bar" target="fail" />
        </state>
        <state id="s2">
            <transition cond="Var1==0" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test153 - iteration order and item assignment, nested <if>/<else>" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
            <data id="Var2" />
            <data id="Var3">[1,2,3]</data>
            <data id="Var4" expr="1" />
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var2" array="Var3">
                    <if cond="Var1&lt;Var2">
                        <assign location="Var1" expr="Var2" />
                        <else />
                        <assign location="Var4" expr="0" />
                    </if>
                </foreach>
            </onentry>
            <transition cond="Var4==0" target="fail" />
            <transition target="pass" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test155 - body <assign> accumulates across iterations" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
            <data id="Var2" />
            <data id="Var3">[1,2,3]</data>
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var2" array="Var3">
                    <assign location="Var1" expr="Var1 + Var2" />
                </foreach>
            </onentry>
            <transition cond="Var1==6" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test156 - a mid-loop child error halts the loop and block, keeping prior mutations" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
            <data id="Var2" />
            <data id="Var3">[1,2,3]</data>
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var2" array="Var3">
                    <assign location="Var1" expr="Var1 + 1" />
                    <assign location="Var5" expr="return" />
                </foreach>
            </onentry>
            <transition cond="Var1==1" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCXML mandatory/foreach/test525 - iterates a shallow copy; mutating array's source mid-loop does not affect iteration" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" version="1.0">
        <datamodel>
            <data id="Var1">[1,2,3]</data>
            <data id="Var2" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <foreach item="Var3" array="Var1">
                    <assign location="Var1" expr="concat(Var1, [4])" />
                    <assign location="Var2" expr="Var2 + 1" />
                </foreach>
            </onentry>
            <transition cond="Var2==3" target="pass" />
            <transition target="fail" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: see test150 above - same mutation, same reasoning.
  test "SCION foreach/test1 - 0-based index, a second <foreach> with no index, ECMAScript-syntax conds" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!--
       Copyright 2011-2012 Jacob Beard, INFICON, and other SCION contributors

       Licensed under the Apache License, Version 2.0 (the "License");
       you may not use this file except in compliance with the License.
       You may obtain a copy of the License at

           http://www.apache.org/licenses/LICENSE-2.0

       Unless required by applicable law or agreed to in writing, software
       distributed under the License is distributed on an "AS IS" BASIS,
       WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
       See the License for the specific language governing permissions and
       limitations under the License.
    -->
    <!--
         This test illustrates how possibly infinite loops may be created. Here, without the counter and the cond, the big-step would never complete.
         -->
    <scxml
        datamodel="ecmascript"
        xmlns="http://www.w3.org/2005/07/scxml"
        version="1.0">

        <datamodel>
            <data id="myArray" expr="[1,3,5,7,9]"/>
            <data id="myItem" expr="0"/>
            <data id="myIndex" expr="0"/>
            <data id="sum" expr="0"/>
            <data id="indexSum" expr="0"/>
        </datamodel>

        <state id="a">
            <onentry>
                <log label="before" expr="[sum,indexSum]"/>
                <foreach array="myArray" item="myItem" index="myIndex">
                    <assign location="sum" expr="sum + myItem"/>
                    <assign location="indexSum" expr="indexSum + myIndex"/>
                </foreach>
                <foreach array="myArray" item="myItem">
                    <assign location="sum" expr="sum + myItem"/>
                </foreach>
                <log label="after" expr="[sum,indexSum]"/>
            </onentry>
            <transition target="c" event="t" cond="sum === 50 &amp;&amp; indexSum === 10"/>
        </state>

        <state id="c"/>

    </scxml>
    """

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["a"])

    {:ok, next_state_chart, next_effects} = Statifier.send_event(state_chart, "t")

    assert active_states(next_state_chart, next_effects) == MapSet.new(["c"])
  end
end
