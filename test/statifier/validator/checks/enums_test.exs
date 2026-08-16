defmodule Statifier.Validator.Checks.EnumsTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - transition_bad_type" do
    # sabotage: out_of_range/5 stops slicing the source and tests the lowered
    # atom instead (`transition.type in [:internal, :external]`), which is
    # true for every value lowering produces since it maps out-of-range text
    # onto the :external default -> nothing is reported at all, reddening
    # this assertion
    test "an out-of-range transition type is reported with the source text" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition event="e" target="b" type="sideways"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_bad_type, "sideways"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message == ~s(transition type "sideways" must be "internal" or "external")
    end

    # sabotage: @transition_types drops "internal", keeping only "external"
    # -> the legal type="internal" below is reported as out of range,
    # reddening this {:ok, _} assertion
    test "both legal transition types report nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition event="e" target="b" type="internal"/>
              <transition event="f" target="b" type="external"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: out_of_range/5's `:error` arm returns a report built from
    # `Location.slice/2` over a zero-width span (treating an absent
    # attribute as an empty written one) instead of [] -> every transition
    # without a type attribute gains a spurious :transition_bad_type error,
    # reddening this {:ok, _} assertion
    test "a transition with no type attribute reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: transition_type_errors/1 keeps only `{:plain, _}` owners out
    # of `context.transitions`, the way a walk over `state.transitions`
    # alone would -> the <initial> element's and the <history>'s transitions
    # are no longer reached, so one of these three errors comes back instead
    # of three, reddening the count assertion
    test "transitions under <initial> and <history> are covered too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="b" type="sideways"/>
              </initial>
              <state id="b"/>
              <state id="c">
                  <transition event="e" target="b" type="upward"/>
              </state>
              <history id="h">
                  <transition target="b" type="inward"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert [{:transition_bad_type, "sideways"}, {:transition_bad_type, "upward"}] =
               errors
               |> Enum.map(& &1.reason)
               |> Enum.filter(&(elem(&1, 0) == :transition_bad_type))
               |> Enum.take(2)

      assert Enum.count(errors, &(elem(&1.reason, 0) == :transition_bad_type)) == 3
    end
  end

  describe "check/2 - scxml_bad_binding" do
    # sabotage: binding_errors/2 reads `document.attribute_locations[:xmlns]`
    # instead of `[:binding]` -> the sliced text is the namespace URI rather
    # than the binding value, so the reason no longer carries "whenever",
    # reddening this assertion
    test "an out-of-range binding is reported with the source text" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" binding="whenever">
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:scxml_bad_binding, "whenever"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 1
      assert error.message == ~s(binding "whenever" must be "early" or "late")
    end

    # sabotage: @bindings drops "late", keeping only "early" -> the legal
    # binding="late" below is reported as out of range, reddening this
    # {:ok, _} assertion
    test "both legal bindings report nothing" do
      for binding <- ["early", "late"] do
        xml = """
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" binding="#{binding}">
            <state id="a"/>
        </scxml>
        """

        assert {:ok, _document, _warnings} = validate!(xml)
      end
    end

    # sabotage: out_of_range/5's `:error` arm (shared with the transition
    # type check above) reports a zero-width span instead of returning [],
    # treating an absent attribute as a written empty one -> a document with
    # no binding attribute gains a spurious :scxml_bad_binding, reddening
    # this {:ok, _} assertion
    test "a document with no binding attribute reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - scxml_bad_datamodel" do
    # sabotage: datamodel_errors/2 reads
    # `document.attribute_locations[:binding]` instead of `[:datamodel]` ->
    # the sliced text is the binding value rather than the datamodel one, so
    # the reason no longer carries "cobol", reddening this assertion
    test "an out-of-range datamodel is reported with the source text" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="cobol">
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:scxml_bad_datamodel, "cobol"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 1
      assert error.message =~ "cobol"
    end

    # sabotage: @datamodels drops "ecmascript" -> the 86 SCION ratchet
    # entries that carry datamodel="ecmascript" would regress, reddening
    # this assertion (Decision 9,
    # docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md)
    test "datamodel=\"ecmascript\" still validates" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="ecmascript">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: same drop as above, exercised for every allowed value at
    # once rather than "ecmascript" alone
    test "every allowed datamodel value reports nothing" do
      for datamodel <- ["predicator", "elixir", "null", "ecmascript", "xpath"] do
        xml = """
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="#{datamodel}">
            <state id="a"/>
        </scxml>
        """

        assert {:ok, _document, _warnings} = validate!(xml)
      end
    end

    # sabotage: out_of_range/5's `:error` arm (shared with the other two
    # enumerated attributes above) reports a zero-width span instead of
    # returning [], treating an absent attribute as a written empty one ->
    # a document with no datamodel attribute gains a spurious
    # :scxml_bad_datamodel, reddening this {:ok, _} assertion
    test "a document with no datamodel attribute reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - invoke_bad_autoforward" do
    # sabotage: `autoforward_errors/2` reads
    # `invoke.attribute_locations[:namelist]` instead of `[:autoforward]` ->
    # the sliced text is the namelist value rather than the autoforward one,
    # so the reason no longer carries "sideways", reddening this assertion
    test "an out-of-range autoforward value is reported with the source text" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <invoke type="t" autoforward="sideways"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_bad_autoforward, "sideways"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message == ~s(invoke autoforward "sideways" must be "true" or "false")
    end

    # sabotage: @autoforwards drops "false", keeping only "true" -> the
    # legal autoforward="false" below is reported as out of range, reddening
    # this {:ok, _} assertion
    test "both legal autoforward values report nothing" do
      for autoforward <- ["true", "false"] do
        xml = """
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
            <state id="a">
                <invoke type="t" autoforward="#{autoforward}"/>
            </state>
        </scxml>
        """

        assert {:ok, _document, _warnings} = validate!(xml)
      end
    end

    # sabotage: `autoforward_errors/2` drops its `flatten/1` step, walking
    # only `document.states` directly instead of every nested state -> an
    # `<invoke>` under a nested `<state>` is no longer reached, reddening
    # this assertion
    test "an <invoke> under a nested state is covered too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b">
                  <invoke type="t" autoforward="sideways"/>
              </state>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_bad_autoforward, "sideways"}}], _warnings} =
               validate!(xml)
    end

    # sabotage: out_of_range/5's `:error` arm (shared with the other
    # enumerated attributes above) reports a zero-width span instead of
    # returning [], treating an absent attribute as a written empty one ->
    # an <invoke> with no autoforward attribute gains a spurious
    # :invoke_bad_autoforward, reddening this {:ok, _} assertion
    test "an <invoke> with no autoforward attribute reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <invoke type="t"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - the history type attribute stays check 5's" do
    # sabotage: Checks.Enums grows a `:history` arm reporting
    # :transition_bad_type for a <history type="...">, the duplication this
    # module's moduledoc says it deliberately leaves to Checks.History ->
    # the <history> below reports two errors instead of one, reddening the
    # single-element list match
    test "an out-of-range history type is reported once, as :history_bad_type" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h" type="sideways">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_type, "sideways"}}], _warnings} =
               validate!(xml)
    end
  end
end
