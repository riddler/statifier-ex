defmodule Mix.Statifier.Corpus.PositionExpectationTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.Corpus.{PositionExpectation, Runner}

  # A step's expect_position (ADR-0076), checked by Runner.run_case/1 and
  # rendered by PositionExpectation.render/1. The charts are the library
  # world's (conformance/README.md); the session runtime is the one
  # test_helper.exs places.

  @patron """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="patron">
      <datamodel>
          <data id="patron_id" expr="'p-1'"/>
      </datamodel>
      <parallel id="patron">
          <state id="standing" initial="good">
              <state id="good">
                  <transition event="patron.blocked" target="blocked"/>
              </state>
              <state id="blocked"/>
          </state>
          <state id="fines" initial="none">
              <state id="none">
                  <transition event="fine.assessed" target="owed"/>
              </state>
              <state id="owed"/>
          </state>
      </parallel>
  </scxml>
  """

  @after_fine %{
    "configuration" => ["fines", "good", "owed", "patron", "standing"],
    "entered_states" => ["fines", "good", "none", "owed", "patron", "standing"],
    "states_to_invoke" => [],
    "history_values" => %{},
    "active_invocations" => [],
    "running" => true,
    "datamodel" => %{"patron_id" => "p-1"}
  }

  defp patron_case(expected, fields \\ %{}) do
    Map.merge(
      %{
        "id" => "statifier/library/patron_position",
        "source" => @patron,
        "description" => "",
        "initial_configuration" => ["good", "none"],
        "steps" => [
          %{
            "event" => %{"name" => "fine.assessed"},
            "configuration" => ["good", "owed"],
            "expect_position" => expected
          }
        ]
      },
      fields
    )
  end

  describe "Runner.run_case/1 with a step's expect_position" do
    # sabotage: PositionExpectation's ids/1 returning the export's MapSet
    # instead of a sorted list -> the rendering is not the expectation -> red
    test "agrees on a case with no host object when the position is the expected one" do
      assert Runner.run_case(patron_case(@after_fine)) == :agree
    end

    # sabotage: HostCase's position/3 answering :ok without comparing ->
    # the wrong expectation agrees -> red; run_case/1 sending a case with
    # no host object to test_scxml/4 whatever its steps carry -> red
    test "disagrees on a wrong expect_position, naming the step and the member" do
      wrong = put_in(@after_fine, ["datamodel", "patron_id"], "p-2")

      assert {:disagree, message} = Runner.run_case(patron_case(wrong))

      assert message ==
               ~s|after step 1 (fine.assessed), expect_position differs: | <>
                 ~s|datamodel: expected {"patron_id":"p-2"}, but got {"patron_id":"p-1"}|
    end

    # sabotage: HostCase's position/3 answering :ok without comparing -> red
    test "checks a case that carries a host object too" do
      loan = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="on_loan">
          <datamodel>
              <data id="renewals" expr="0"/>
          </datamodel>
          <state id="on_loan">
              <onentry>
                  <send type="library:timer" target="loan" event="loan.due" id="due" delay="21d"/>
              </onentry>
              <transition event="loan.renew" target="on_loan">
                  <assign location="renewals" expr="renewals + 1"/>
              </transition>
          </state>
      </scxml>
      """

      due = %{
        "type" => "library:timer",
        "target" => "loan",
        "event" => %{"name" => "loan.due"},
        "delay_ms" => 1_814_400_000,
        "send_id" => "due"
      }

      expected = %{
        @after_fine
        | "configuration" => ["on_loan"],
          "entered_states" => ["on_loan"],
          "datamodel" => %{"renewals" => 1}
      }

      loan_case = fn expected ->
        %{
          "id" => "statifier/library/loan_position",
          "source" => loan,
          "description" => "",
          "initial_configuration" => ["on_loan"],
          "steps" => [
            %{
              "event" => %{"name" => "loan.renew"},
              "configuration" => ["on_loan"],
              "expect_position" => expected
            }
          ],
          "host" => %{
            "send_types" => ["library:timer", "library:route"],
            "expect_sends" => [due, due]
          }
        }
      end

      assert Runner.run_case(loan_case.(expected)) == :agree

      assert {:disagree, message} =
               Runner.run_case(loan_case.(put_in(expected, ["datamodel", "renewals"], 0)))

      assert message =~ ~s|datamodel: expected {"renewals":0}, but got {"renewals":1}|
    end

    # sabotage: HostCase's position/3 fallback clause answering a
    # disagreement -> the step without an expectation disagrees -> red
    test "compares nothing on a step that carries no expect_position" do
      steps = [
        %{"event" => %{"name" => "patron.blocked"}, "configuration" => ["blocked", "none"]},
        %{
          "event" => %{"name" => "fine.assessed"},
          "configuration" => ["blocked", "owed"],
          "expect_position" =>
            Map.merge(@after_fine, %{
              "configuration" => ["blocked", "fines", "owed", "patron", "standing"],
              "entered_states" => [
                "blocked",
                "fines",
                "good",
                "none",
                "owed",
                "patron",
                "standing"
              ]
            })
        }
      ]

      assert Runner.run_case(patron_case(nil, %{"steps" => steps})) == :agree
    end

    # sabotage: HostCase's named/2 answering :ok whatever the case carries
    # -> the nameless state is never active, so the export does not refuse
    # and the case agrees -> red
    test "disagrees when a state of the document has no id" do
      nameless =
        String.replace(
          @patron,
          ~s|<state id="owed"/>|,
          ~s|<state id="owed"/>\n            <state><transition event="fine.paid" target="none"/></state>|
        )

      assert {:disagree, message} =
               Runner.run_case(patron_case(@after_fine, %{"source" => nameless}))

      assert message ==
               "a case that expects a position needs every state to carry an id, " <>
                 "and 1 state(s) of this document have none"
    end

    # sabotage: Statifier.Interpreter's main_event_loop/3 (outside this
    # change) clearing states_to_invoke in its not-running branch before
    # exit_interpreter/1 -> the ending step's position states [] -> red
    test "after the step that ends the chart, states_to_invoke keeps the states entered since the last invoke pass" do
      loan = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="on_loan">
          <state id="on_loan">
              <transition event="copy.returned" target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      returned = %{
        "configuration" => [],
        "entered_states" => ["on_loan", "returned"],
        "states_to_invoke" => ["returned"],
        "history_values" => %{},
        "active_invocations" => [],
        "running" => false,
        "datamodel" => %{}
      }

      loan_case = %{
        "id" => "statifier/library/loan_returned_position",
        "source" => loan,
        "description" => "",
        "initial_configuration" => ["on_loan"],
        "steps" => [
          %{
            "event" => %{"name" => "copy.returned"},
            "configuration" => ["returned"],
            "expect_position" => returned
          }
        ]
      }

      assert Runner.run_case(loan_case) == :agree
    end

    # sabotage: Statifier.Interpreter.ExitEntry's exit_states/2 (outside this
    # change) keeping states_to_invoke instead of removing the exit set ->
    # check_in stays in it -> red
    test "after the step that ends the chart, states_to_invoke leaves out a state the step entered and exited" do
      loan = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="on_loan">
          <state id="on_loan">
              <transition event="copy.returned" target="check_in"/>
          </state>
          <state id="check_in">
              <transition target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      returned = %{
        "configuration" => [],
        "entered_states" => ["check_in", "on_loan", "returned"],
        "states_to_invoke" => ["returned"],
        "history_values" => %{},
        "active_invocations" => [],
        "running" => false,
        "datamodel" => %{}
      }

      loan_case = %{
        "id" => "statifier/library/loan_checked_in_position",
        "source" => loan,
        "description" => "",
        "initial_configuration" => ["on_loan"],
        "steps" => [
          %{
            "event" => %{"name" => "copy.returned"},
            "configuration" => ["returned"],
            "expect_position" => returned
          }
        ]
      }

      assert Runner.run_case(loan_case) == :agree
    end

    # sabotage: compare/3 matching the rendering against the expectation
    # strictly (`{:ok, ^expected}`) again -> the float 2.0 disagrees with
    # the case's 2 -> red
    test "agrees when a number the chart holds as a float is the expectation's integer" do
      fines = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="clear">
          <datamodel>
              <data id="fine_total" expr="0.5"/>
          </datamodel>
          <state id="clear">
              <transition event="fine.assessed" target="owed">
                  <assign location="fine_total" expr="fine_total + 1.5"/>
              </transition>
          </state>
          <state id="owed"/>
      </scxml>
      """

      owed = %{
        "configuration" => ["owed"],
        "entered_states" => ["clear", "owed"],
        "states_to_invoke" => [],
        "history_values" => %{},
        "active_invocations" => [],
        "running" => true,
        "datamodel" => %{"fine_total" => 2}
      }

      fines_case = fn expected ->
        %{
          "id" => "statifier/library/patron_fine_position",
          "source" => fines,
          "description" => "",
          "initial_configuration" => ["clear"],
          "steps" => [
            %{
              "event" => %{"name" => "fine.assessed"},
              "configuration" => ["owed"],
              "expect_position" => expected
            }
          ]
        }
      end

      assert Runner.run_case(fines_case.(owed)) == :agree

      assert {:disagree, message} =
               Runner.run_case(fines_case.(put_in(owed, ["datamodel", "fine_total"], 3)))

      assert message ==
               ~s|after step 1 (fine.assessed), expect_position differs: | <>
                 ~s|datamodel: expected {"fine_total":3}, but got {"fine_total":2.0}|
    end
  end

  describe "compare/3" do
    defp patron_after_fine(datamodel) do
      {:ok, machine} = Statifier.compile(@patron)
      {machine_state, _effects} = Statifier.initialize(machine)
      {:ok, machine_state, _effects} = Statifier.send_event(machine_state, "fine.assessed")
      %{machine_state | datamodel: Map.merge(machine_state.datamodel, datamodel)}
    end

    defp expecting(datamodel),
      do: put_in(@after_fine, ["datamodel"], Map.merge(%{"patron_id" => "p-1"}, datamodel))

    # sabotage: same?/2's number clause comparing with === -> each float
    # disagrees with the integer it equals -> red
    test "compares numbers by JSON value, at the top of the datamodel and inside an array or object" do
      position = patron_after_fine(%{"fine_total" => 2.0, "holds" => [%{"position" => 1.0}]})

      assert PositionExpectation.compare(
               expecting(%{"fine_total" => 2, "holds" => [%{"position" => 1}]}),
               position,
               {1, "fine.assessed"}
             ) == :ok

      assert PositionExpectation.compare(
               expecting(%{"fine_total" => 2.0, "holds" => [%{"position" => 1.0}]}),
               patron_after_fine(%{"fine_total" => 2, "holds" => [%{"position" => 1}]}),
               {1, "fine.assessed"}
             ) == :ok
    end

    # sabotage: same?/2's number clause answering true for every pair of
    # numbers -> the 2.5 agrees with the 2 -> red
    test "names the member whose number differs by value" do
      assert {:disagree, message} =
               PositionExpectation.compare(
                 expecting(%{"fine_total" => 2}),
                 patron_after_fine(%{"fine_total" => 2.5}),
                 {1, "fine.assessed"}
               )

      assert message ==
               ~s|after step 1 (fine.assessed), expect_position differs: | <>
                 ~s|datamodel: expected {"fine_total":2,"patron_id":"p-1"}, | <>
                 ~s|but got {"fine_total":2.5,"patron_id":"p-1"}|
    end

    # sabotage: same?/2's fallback clause answering true -> the string "2"
    # agrees with the number 2 -> red
    test "keeps a number apart from a string, a boolean and null" do
      for {expected, got} <- [{2, "2"}, {1, true}, {0, nil}] do
        assert {:disagree,
                "after step 1 (fine.assessed), expect_position differs: datamodel: " <>
                  _rest} =
                 PositionExpectation.compare(
                   expecting(%{"fine_total" => expected}),
                   patron_after_fine(%{"fine_total" => got}),
                   {1, "fine.assessed"}
                 )
      end
    end

    # sabotage: same?/2's list clause sorting both sides before comparing
    # -> the reordered configuration agrees -> red; its map clause without
    # the map_size/1 test -> the extra copy_id member agrees -> red
    test "compares arrays in order and objects by their members" do
      reordered = %{@after_fine | "configuration" => Enum.reverse(@after_fine["configuration"])}

      assert {:disagree, message} =
               PositionExpectation.compare(
                 reordered,
                 patron_after_fine(%{}),
                 {1, "fine.assessed"}
               )

      assert message =~ "expect_position differs: configuration: expected"

      assert {:disagree, message} =
               PositionExpectation.compare(
                 expecting(%{"holds" => [%{"position" => 1}]}),
                 patron_after_fine(%{"holds" => [%{"position" => 1, "copy_id" => "c-1"}]}),
                 {1, "fine.assessed"}
               )

      assert message =~ "expect_position differs: datamodel: expected"
    end
  end

  describe "render/1" do
    defp initialized(source, events \\ []) do
      {:ok, machine} = Statifier.compile(source)
      {machine_state, _effects} = Statifier.initialize(machine)

      Enum.reduce(events, machine_state, fn event, acc ->
        {:ok, next, _effects} = Statifier.send_event(acc, event)
        next
      end)
    end

    # sabotage: drop_unset_name/2's fallback clause keeping "_name" -> the
    # unset _name renders as null -> red; value/1's :undefined clause
    # removed -> red, refused
    test "leaves out the four system variables of a document with no name, and writes an undefined value as null" do
      machine_state = initialized(@patron)

      assert ~w(_event _ioprocessors _name _sessionid patron_id) ==
               machine_state.datamodel |> Map.keys() |> Enum.sort()

      assert {:ok, %{"datamodel" => datamodel}} = PositionExpectation.render(machine_state)
      assert datamodel == %{"patron_id" => "p-1"}

      due = put_in(machine_state.datamodel["due_at"], :undefined)

      assert {:ok, %{"datamodel" => datamodel}} = PositionExpectation.render(due)
      assert datamodel == %{"patron_id" => "p-1", "due_at" => nil}
    end

    # sabotage: drop_unset_name/2's binary clause deleting "_name" as the
    # fallback does -> the named document's _name is left out -> red;
    # "_name" back in @left_out_variables -> red
    test "writes _name when the document's scxml element carries a name attribute" do
      named =
        String.replace(
          @patron,
          ~s|datamodel="predicator" initial="patron">|,
          ~s|datamodel="predicator" name="patron_record" initial="patron">|
        )

      machine_state = initialized(named)

      assert {:ok, %{"datamodel" => datamodel}} = PositionExpectation.render(machine_state)
      assert datamodel == %{"_name" => "patron_record", "patron_id" => "p-1"}
    end

    # sabotage: value/1's fallback clause answering {:ok, value} -> the Date
    # renders -> red; its list clause removed -> red on the holds list
    test "writes lists and string-keyed maps member by member, and refuses a value with no JSON form" do
      machine_state = initialized(@patron)
      holds = [%{"copy_id" => "c-1", "position" => 1}]

      assert {:ok, %{"datamodel" => %{"holds" => ^holds}}} =
               PositionExpectation.render(put_in(machine_state.datamodel["holds"], holds))

      assert {:error, "the datamodel's due_on holds ~D[2026-10-23], which has no JSON form here"} =
               PositionExpectation.render(
                 put_in(machine_state.datamodel["due_on"], ~D[2026-10-23])
               )

      assert {:error, "the datamodel's holds holds" <> _rest} =
               PositionExpectation.render(put_in(machine_state.datamodel["holds"], [{:copy, 1}]))
    end

    # sabotage: render/1 writing history_values as the export's map of
    # MapSets -> red
    test "writes each history value under its history state's id, sorted" do
      loan = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="active">
          <state id="active" initial="on_loan">
              <history id="h" type="deep">
                  <transition target="on_loan"/>
              </history>
              <state id="on_loan">
                  <transition event="loan.due_soon" target="due_soon"/>
              </state>
              <state id="due_soon"/>
              <transition event="copy.disputed" target="held_for_review"/>
          </state>
          <state id="held_for_review">
              <transition event="dispute.resolved" target="h"/>
          </state>
      </scxml>
      """

      machine_state = initialized(loan, ["loan.due_soon", "copy.disputed"])

      assert {:ok, %{"configuration" => ["held_for_review"], "history_values" => history}} =
               PositionExpectation.render(machine_state)

      assert history == %{"h" => ["due_soon"]}
    end

    # sabotage: invocations/1 writing the invocation's id as its index -> red
    test "writes each active invocation as its state and index, without its id" do
      hold_queue = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="awaiting_pickup">
          <state id="awaiting_pickup">
              <invoke type="scxml" id="pickup_window">
                  <content><scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator"><state id="open"/></scxml></content>
              </invoke>
              <invoke type="scxml">
                  <content><scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator"><state id="open"/></scxml></content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:ok, %{"active_invocations" => invocations}} =
               hold_queue |> initialized() |> PositionExpectation.render()

      assert invocations == [
               %{"state" => "awaiting_pickup", "index" => 0},
               %{"state" => "awaiting_pickup", "index" => 1}
             ]
    end
  end
end
