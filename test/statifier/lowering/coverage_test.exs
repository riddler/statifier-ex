defmodule Statifier.Lowering.CoverageTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser

  # The same 25-name vocabulary `test/statifier/parser/generic_handler_test.exs`
  # scans for, kept as its own copy: `lib/` may not reference `test/support/`
  # (ADR-0006) and this guard belongs to the lowering layer, not the
  # parser's. The two lists are kept in sync by manual inspection, not a
  # shared source.
  @scxml_element_names ~w(
    scxml state parallel final initial history transition onentry onexit
    datamodel data log raise assign send param content if elseif else
    foreach invoke donedata cancel script
  )

  # The dispatch map's own thirteen keys (`lib/statifier/lowering.ex`),
  # duplicated here as data rather than imported - there is nothing in
  # `lib/` to import, since the map itself is a private module attribute.
  @supported ~w(
    scxml state parallel final history initial transition onentry onexit
    raise log donedata content
  )

  # The twelve names `@phase_3_elements` exists to word the unsupported-
  # element message for - deferred, not partially built.
  @phase_3_elements ~w(
    datamodel data assign send param if elseif else foreach invoke cancel
    script
  )

  # One minimal, spec-legal fixture per known element name. `<data>`'s only
  # spec-legal parent is `<datamodel>`, which is itself unsupported and so
  # never recursed into (`Lowering.walk_child/4` does not walk an
  # unsupported element's children) - a `<datamodel><data/></datamodel>`
  # fixture would only ever surface `"datamodel"` as the error, never
  # reaching `"data"` at all. `<data>` is therefore placed directly under
  # `<scxml>` instead (a deliberate deviation from a spec-legal position),
  # which still proves the name itself is rejected, just not in a
  # spec-legal position.
  @fixtures %{
    "scxml" => ~s(<scxml/>),
    "state" => ~s(<scxml><state id="s"/></scxml>),
    "parallel" => ~s(<scxml><parallel id="p"/></scxml>),
    "final" => ~s(<scxml><final id="f"/></scxml>),
    "history" => ~s(<scxml><state id="s"><history id="h"/></state></scxml>),
    "initial" =>
      ~s(<scxml><state id="s"><initial><transition target="s"/></initial></state></scxml>),
    "transition" => ~s(<scxml><state id="s"><transition target="s"/></state></scxml>),
    "onentry" => ~s(<scxml><state id="s"><onentry/></state></scxml>),
    "onexit" => ~s(<scxml><state id="s"><onexit/></state></scxml>),
    "raise" => ~s(<scxml><state id="s"><onentry><raise event="e"/></onentry></state></scxml>),
    "log" => ~s(<scxml><state id="s"><onentry><log/></onentry></state></scxml>),
    "donedata" => ~s(<scxml><final id="f"><donedata/></final></scxml>),
    "content" => ~s(<scxml><final id="f"><donedata><content/></donedata></final></scxml>),
    "datamodel" => ~s(<scxml><datamodel/></scxml>),
    "data" => ~s(<scxml><data id="x"/></scxml>),
    "assign" =>
      ~s(<scxml><state id="s"><transition><assign location="x" expr="1"/></transition></state></scxml>),
    "send" => ~s(<scxml><state id="s"><onentry><send event="e"/></onentry></state></scxml>),
    "param" => ~s(<scxml><final id="f"><donedata><param name="x"/></donedata></final></scxml>),
    "if" => ~s(<scxml><state id="s"><onentry><if cond="true"/></onentry></state></scxml>),
    "elseif" => ~s(<scxml><state id="s"><onentry><elseif cond="true"/></onentry></state></scxml>),
    "else" => ~s(<scxml><state id="s"><onentry><else/></onentry></state></scxml>),
    "foreach" => ~s(<scxml><state id="s"><onentry><foreach item="x"/></onentry></state></scxml>),
    "invoke" => ~s(<scxml><state id="s"><invoke type="t"/></state></scxml>),
    "cancel" => ~s(<scxml><state id="s"><onexit><cancel sendid="s1"/></onexit></state></scxml>),
    "script" => ~s(<scxml><script>1;</script></scxml>)
  }

  defp lower(xml) do
    {:ok, root} = Parser.parse(xml)
    Lowering.lower(root)
  end

  # sabotage: n/a - a completeness check on the test's own two hardcoded
  # lists against the shared name vocabulary, no lib/ behavior
  test "the supported/deferred lists partition the known element names cleanly" do
    supported = MapSet.new(@supported)
    deferred = MapSet.new(@phase_3_elements)
    known = MapSet.new(@scxml_element_names)

    assert MapSet.union(supported, deferred) == known
    assert MapSet.intersection(supported, deferred) == MapSet.new()
  end

  # sabotage: n/a - a fixture-table completeness check, no lib/ behavior
  test "the fixture table covers every known element name" do
    assert @fixtures |> Map.keys() |> Enum.sort() == Enum.sort(@scxml_element_names)
  end

  # sabotage: drop `"final" => &Builders.build_final/2` from `Lowering`'s
  # dispatch map - "final" is still listed here as supported, but its
  # fixture now produces `{:unsupported_element, "final"}` instead of
  # building, and the `{:ok, _}` assertion below reddens for "final"
  # specifically
  test "every supported element name builds successfully" do
    for name <- @supported do
      xml = Map.fetch!(@fixtures, name)
      assert {:ok, _document} = lower(xml), "#{name} was expected to build, but did not"
    end
  end

  # sabotage: `Lowering`'s dispatch map grows a stray
  # `"param" => &Builders.build_state/2` entry (an accidental extra
  # dispatch) -> `<param>`'s fixture now builds instead of producing
  # `{:unsupported_element, "param"}`, and the assertion below reddens
  test "every deferred element name is rejected, naming itself" do
    for name <- @phase_3_elements do
      xml = Map.fetch!(@fixtures, name)

      assert {:error, errors} = lower(xml), "#{name} was expected to be rejected, but built"

      assert Enum.any?(errors, &match?(%Error{reason: {:unsupported_element, ^name}}, &1)),
             "#{name}'s own name was not reported unsupported: #{inspect(errors)}"
    end
  end
end
