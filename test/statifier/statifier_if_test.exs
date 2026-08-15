defmodule Statifier.StatifierIfTest do
  @moduledoc """
  Drives the five `<if>`/`<elseif>`/`<else>` corpus documents listed below
  through the real engine, end to end, without going through
  `Statifier.Case.test_scxml/4`.

  That was deliberate, not an oversight: until bead **st-af3.8**, all eight
  `if_elements` corpus files also tripped `conditional_transitions`
  (`test/support/feature_detector.ex:68`, then `:unsupported` - the
  `~r/\bcond\s*=/` attribute detector fires on `<if cond=...>` and
  `<elseif cond=...>` exactly as it does on `<transition cond=...>`).
  `Statifier.Case.test_scxml/4` flunks rather than skips a document that names
  an unsupported feature (`test/support/case.ex:41-46`), so these five flunked
  before that bead even though `<if>`/`<elseif>`/`<else>` themselves were
  already fully implemented and correct.

  st-af3.8 flipped `conditional_transitions` to `:supported`, ran the full
  conformance suites, and ratcheted `test/passing_tests.json`
  (`mix test.baseline add`), so
  `test/scion_tests/if_else/test0_test.exs`,
  `test/scxml_tests/mandatory/if/test147_test.exs`, `test148_test.exs`,
  `test149_test.exs`, and
  `test/scxml_tests/mandatory/system_variables/test319_test.exs` are now
  feature-clean and run through the generated harness too.

  This file is **not** a duplicate to delete now that that has landed: it drives the
  exact same documents through `Statifier.compile/1`, `Statifier.initialize/2`,
  `Statifier.send_event/2`, and `Statifier.active_leaf_states/1` - the same
  four-function public API `Statifier.Case`'s own private helpers use
  (`test/support/case.ex:16-21`) - and stays the only place in the suite that
  proves this behavior under a bare `mix test`, since the generated files stay
  tagged `:scion`/`:scxml_w3` and excluded from the default run
  (`test/test_helper.exs`). It remains valuable afterward as fast, always-on
  coverage of `<if>`/`<elseif>`/`<else>` that does not depend on the ratchet.

  Each XML fixture below is byte-identical to the corresponding generated
  corpus file's own heredoc - copied, not paraphrased, so this test proves the
  real document.
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

  # sabotage: Statifier.Machine.Content.If's select/3 skips a nil-cond
  # (`<else>`) branch instead of selecting it -> "test319" below (whose
  # `<else/>` is the only branch that can be selected, since `_event` is
  # unbound at initialization) -> red
  test "SCION if_else/test0 - if/elseif/else, nesting, and cross-block assign visibility" do
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
    <scxml 
        datamodel="ecmascript"
        xmlns="http://www.w3.org/2005/07/scxml"
        version="1.0">

        <datamodel>
            <data id="x" expr="0"/>
        </datamodel>

        <state id="a">
            <onentry>
                <!-- test if -->
                <log label="x" expr="x"/>
                <if cond="x === 0">
                    <assign location="x" expr="10"/>
                    <elseif cond="x === 10"/>
                    <assign location="x" expr="20"/>
                    <else/>
                    <assign location="x" expr="30"/>
                </if>
                <log label="x" expr="x"/>
            </onentry>

            <transition  event="t" target="b" cond="x === 10">
                <assign location="x" expr="x + 1"/>
            </transition>

            <onexit>
                <!-- test else -->
                <log label="x" expr="x"/>
                <if cond="x !== 10">
                    <assign location="x" expr="x * 3"/>
                    <else/>
                    <assign location="x" expr="x * 2"/>
                </if>
                <log label="x" expr="x"/>
            </onexit>
        </state>

        <state id="b">
            <onentry>
                <!-- test elseif -->
                <log label="x" expr="x"/>
                <if cond="x === 0">
                    <assign location="x" expr="100"/>
                    <elseif cond="x === 21"/>
                    <assign location="x" expr="x + 2"/>
                    <assign location="x" expr="x + 3"/>
                    <else/>
                    <assign location="x" expr="200"/>
                </if>

                <if cond="x === 26">
                    <assign location="x" expr="x + 1"/>
                </if>

                <if cond="x === 26">
                    <elseif cond="x === 27"/>
                    <assign location="x" expr="x + 1"/>
                    <else/>
                    <assign location="x" expr="x + 10"/>
                </if>

                <if cond="x === 28">
                    <assign location="x" expr="x + 12"/>
                    <if cond="x === 40">
                        <assign location="x" expr="x + 10"/>
                    </if>
                </if>

                <if cond="x === 50">
                    <assign location="x" expr="x + 1"/>
                    <if cond="x !== 51">
                        <else/>
                        <assign location="x" expr="x + 20"/>
                    </if>
                </if>

                <log label="x" expr="x"/>
            </onentry>

            <transition target="c" cond="x === 71"/>
            <transition target="f"/>
        </state>

        <state id="c"/>

        <state id="f"/>

    </scxml>
    """

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["a"])

    {:ok, next_state_chart, next_effects} = Statifier.send_event(state_chart, "t")

    assert active_states(next_state_chart, next_effects) == MapSet.new(["c"])
  end

  # sabotage: `Statifier.Machine.Content.If`'s `select/3` `{:ok, true}` arm
  # scans on (`select(rest, ...)`) instead of returning the branch -> the
  # `<else>` partition runs instead of the first true `<elseif>`, raising
  # `baz` rather than `bar`, so `event="*"` takes s0 to "fail" -> red
  test "SCXML mandatory/if/test147 - first true partition in document order wins" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <if cond="false">
                    <raise event="foo" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <elseif cond="true" />
                    <raise event="bar" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <else />
                    <raise event="baz" />
                    <assign location="Var1" expr="Var1 + 1" />
                </if>
                <raise event="bat" />
            </onentry>
            <transition event="bar" cond="Var1==1" target="pass" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: `Statifier.Machine.Content.If`'s `select/3` `nil`-cond clause
  # skips the `<else>` branch (`select(rest, ...)`) instead of selecting it
  # -> no partition runs at all, `baz` is never raised, so `event="*"` takes
  # s0 to "fail" -> red
  test "SCXML mandatory/if/test148 - else runs when no cond is true" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <if cond="false">
                    <raise event="foo" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <elseif cond="false" />
                    <raise event="bar" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <else />
                    <raise event="baz" />
                    <assign location="Var1" expr="Var1 + 1" />
                </if>
                <raise event="bat" />
            </onentry>
            <transition event="baz" cond="Var1==1" target="pass" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # sabotage: `Statifier.Machine.Content.If`'s `execute/2` runs
  # `hd(branches).content` instead of returning `{:ok, context, []}` when no
  # branch is selected -> `foo` is raised and `Var1` becomes 1, so the
  # `cond="Var1==0"` guard on the "bat" transition no longer holds and
  # `event="*"` takes s0 to "fail" -> red
  test "SCXML mandatory/if/test149 - nothing runs when no cond is true and there is no else" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="Var1" expr="0" />
        </datamodel>
        <state id="s0">
            <onentry>
                <if cond="false">
                    <raise event="foo" />
                    <assign location="Var1" expr="Var1 + 1" />
                    <elseif cond="false" />
                    <raise event="bar" />
                    <assign location="Var1" expr="Var1 + 1" />
                </if>
                <raise event="bat" />
            </onentry>
            <transition event="bat" cond="Var1==0" target="pass" />
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

    machine = compile!(xml)
    {state_chart, effects} = Statifier.initialize(machine)

    assert active_states(state_chart, effects) == MapSet.new(["pass"])
  end

  # Despite the "unbound" in this test's name, `_event !== undefined`
  # evaluates cleanly to `{:ok, false}` here - predicator's `undefined`
  # literal makes unboundness testable rather than an error - so this
  # exercises `select/3`'s ordinary false arm, not its `{:error, _}` one.
  # Mutating the `{:error, _}` arm leaves this test green, which is why the
  # mutation below is the false arm instead.
  #
  # sabotage: `Statifier.Machine.Content.If`'s `select/3` `{:ok, false}` arm
  # returns the branch instead of scanning on -> the `_event !== undefined`
  # partition runs, raising `bound`, which takes s0 to "fail" -> red
  test "SCXML mandatory/system_variables/test319 - _event is unbound at initialization, so else is selected" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s0" datamodel="predicator" version="1.0" name="machineName">
        <state id="s0">
            <onentry>
                <if cond="_event !== undefined">
                    <raise event="bound" />
                    <else />
                    <raise event="unbound" />
                </if>
            </onentry>
            <transition event="unbound" target="pass" />
            <transition event="bound" target="fail" />
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
end
