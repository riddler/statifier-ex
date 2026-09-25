defmodule Mix.Statifier.Corpus.HostCaseTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.Corpus.{HostCase, Runner}

  # A host case run through `Runner.run_case/1`, which hands every case with
  # a `host` object to `Mix.Statifier.Corpus.HostCase`.

  @source """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="awaiting_click">
      <state id="awaiting_click">
          <onentry>
              <send type="myapp:sink" target="impressions" event="impression.recorded"/>
          </onentry>
          <transition event="click.recorded" target="joined">
              <send type="myapp:sink" target="joined_records" event="impression.joined" id="joined">
                  <param name="click_id" expr="'clk-1'"/>
              </send>
              <send type="myapp:sink" target="reminders" event="impression.reminder" delay="5s"/>
          </transition>
      </state>
      <final id="joined"/>
  </scxml>
  """

  @expect_sends [
    %{
      "type" => "myapp:sink",
      "target" => "impressions",
      "event" => %{"name" => "impression.recorded"}
    },
    %{
      "type" => "myapp:sink",
      "target" => "joined_records",
      "event" => %{"name" => "impression.joined", "data" => %{"click_id" => "clk-1"}},
      "send_id" => "joined"
    },
    %{
      "type" => "myapp:sink",
      "target" => "reminders",
      "event" => %{"name" => "impression.reminder"},
      "delay_ms" => 5000
    }
  ]

  defp host_case(fields \\ %{}) do
    Map.merge(
      %{
        "id" => "statifier/send/joined",
        "source" => @source,
        "description" => "",
        "initial_configuration" => ["awaiting_click"],
        "steps" => [
          %{"event" => %{"name" => "click.recorded"}, "configuration" => ["joined"]}
        ],
        "host" => %{"send_types" => ["myapp:sink"], "expect_sends" => @expect_sends}
      },
      fields
    )
  end

  describe "run_case/1 with a host object" do
    # sabotage: `item/2` always writing `send_id` (put_present/3's `nil`
    # clause removed) -> the first send carries `"send_id": nil` and the
    # case disagrees -> red
    test "agrees when the configurations and every handed send match, in order" do
      assert Runner.run_case(host_case()) == :agree
    end

    # sabotage: `handed/2` returning :agree without comparing -> red
    test "disagrees when the handed sends differ, stating both" do
      [_first | rest] = @expect_sends
      host = %{"send_types" => ["myapp:sink"], "expect_sends" => rest}

      assert {:disagree, message} = Runner.run_case(host_case(%{"host" => host}))
      assert message =~ "Expected the sends handed to the host"
      assert message =~ ~s|"target":"impressions"|
    end

    # sabotage: `configuration/2` returning :ok unconditionally -> red
    test "disagrees when a configuration differs" do
      assert {:disagree, message} =
               Runner.run_case(host_case(%{"initial_configuration" => ["joined"]}))

      assert message =~ ~s|Expected active states ["joined"], but got ["awaiting_click"]|
    end

    # sabotage: `run/1` registering "myapp:sink" whatever send_types names ->
    # every send is handed as the case expects -> red
    test "registers only the case's send_types" do
      host = %{"send_types" => ["myapp:other"], "expect_sends" => @expect_sends}

      assert {:disagree, message} = Runner.run_case(host_case(%{"host" => host}))
      assert message =~ "but got []"
    end

    # sabotage: `observed/2`'s `{:done, _}` clause returning the snapshot
    # unchanged -> the terminated chart reads as no active state -> red
    test "reads a terminated chart's configuration off its done effect" do
      steps = [%{"event" => %{"name" => "click.recorded"}, "configuration" => ["awaiting_click"]}]

      assert {:disagree, message} = Runner.run_case(host_case(%{"steps" => steps}))
      assert message =~ ~s|Expected active states ["awaiting_click"], but got ["joined"]|
    end

    # sabotage: `compile/1`'s error arm raising instead -> the rescue still
    # returns a disagreement, but not this message -> red
    test "disagrees, naming the failure, when the document does not compile" do
      assert {:disagree, "the document did not compile: " <> _errors} =
               Runner.run_case(host_case(%{"source" => "<scxml"}))
    end
  end

  describe "run_case/1 with an expect_sends item's outcome" do
    @outcome_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="awaiting_copy">
        <state id="awaiting_copy">
            <transition event="copy.available" target="notifying"/>
            <transition event="copy.reserved" target="on_hold"/>
        </state>
        <state id="notifying">
            <onentry>
                <send type="library:notice" target="patron" event="hold.ready" id="notice"/>
            </onentry>
            <transition event="error.communication" cond="_event.sendid == 'notice'" target="notice_failed"/>
            <transition event="error.communication" target="notice_failed_without_sendid"/>
        </state>
        <state id="notice_failed"/>
        <state id="notice_failed_without_sendid"/>
        <state id="on_hold">
            <onentry>
                <send type="library:timer" target="hold_queue" event="pickup.expired" id="pickup" delay="10ms"/>
            </onentry>
            <transition event="copy.collected" target="collected"/>
            <transition event="hold.withdrawn" target="withdrawn"/>
        </state>
        <state id="collected">
            <onentry>
                <cancel sendid="pickup"/>
            </onentry>
        </state>
        <state id="withdrawn"/>
    </scxml>
    """

    @notice %{
      "type" => "library:notice",
      "target" => "patron",
      "event" => %{"name" => "hold.ready"},
      "send_id" => "notice"
    }

    @pickup %{
      "type" => "library:timer",
      "target" => "hold_queue",
      "event" => %{"name" => "pickup.expired"},
      "delay_ms" => 10,
      "send_id" => "pickup"
    }

    defp outcome_case(steps, expect_sends) do
      %{
        "id" => "statifier/send/outcome",
        "source" => @outcome_source,
        "description" => "",
        "initial_configuration" => ["awaiting_copy"],
        "steps" =>
          Enum.map(steps, fn {name, leaf} ->
            %{"event" => %{"name" => name}, "configuration" => [leaf]}
          end),
        "host" => %{
          "send_types" => ["library:notice", "library:timer"],
          "expect_sends" => expect_sends
        }
      }
    end

    # sabotage: perform_outcome/4's "fail" clause not calling
    # Session.failed_send/3 -> the chart stays in notifying -> red; pump/3
    # reading the expected item one position later -> red
    test "reports a fail item's send through failed_send/3, and the sender reads its sendid" do
      notice = Map.put(@notice, "outcome", "fail")

      assert Runner.run_case(outcome_case([{"copy.available", "notice_failed"}], [notice])) ==
               :agree
    end

    # sabotage: perform_outcome/4's "fail" clause matching any expected item
    # -> the send is reported and the chart reaches notice_failed -> red
    test "reports only the send at a fail item's position" do
      assert {:disagree, message} =
               Runner.run_case(outcome_case([{"copy.available", "notice_failed"}], [@notice]))

      assert message =~ ~s|Expected active states ["notice_failed"], but got ["notifying"]|
    end

    # sabotage: cancel_named/2 returning the handed sends unchanged -> red
    test "agrees on a cancelled item when a cancel naming its send reached the processor" do
      pickup = Map.put(@pickup, "outcome", "cancelled")

      assert Runner.run_case(
               outcome_case([{"copy.reserved", "on_hold"}, {"copy.collected", "collected"}], [
                 pickup
               ])
             ) ==
               :agree
    end

    # sabotage: cancel_named/2 marking every send under the cancel's id,
    # whatever its item says -> red
    test "a cancelled item no cancel reached disagrees, and an item without one claims nothing" do
      pickup = Map.put(@pickup, "outcome", "cancelled")

      assert {:disagree, message} =
               Runner.run_case(
                 outcome_case([{"copy.reserved", "on_hold"}, {"hold.withdrawn", "withdrawn"}], [
                   pickup
                 ])
               )

      assert message =~ ~s|"outcome":"cancelled"|

      assert Runner.run_case(
               outcome_case([{"copy.reserved", "on_hold"}, {"copy.collected", "collected"}], [
                 @pickup
               ])
             ) ==
               :agree
    end
  end

  describe "run_case/1 with a step's event data" do
    @data_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="awaiting_copy">
        <state id="awaiting_copy">
            <transition event="copy.available" cond="_event.data.copy_id == 'c-1'" target="notifying"/>
            <transition event="copy.available" target="copy_unnamed"/>
        </state>
        <state id="notifying">
            <onentry>
                <send type="library:notice" target="patron" event="hold.ready">
                    <param name="copy_id" expr="_event.data.copy_id"/>
                </send>
            </onentry>
        </state>
        <state id="copy_unnamed"/>
    </scxml>
    """

    defp data_case(event) do
      %{
        "id" => "statifier/send/event_data",
        "source" => @data_source,
        "description" => "",
        "initial_configuration" => ["awaiting_copy"],
        "steps" => [%{"event" => event, "configuration" => ["notifying"]}],
        "host" => %{
          "send_types" => ["library:notice"],
          "expect_sends" => [
            %{
              "type" => "library:notice",
              "target" => "patron",
              "event" => %{"name" => "hold.ready", "data" => %{"copy_id" => "c-1"}}
            }
          ]
        }
      }
    end

    # sabotage: event/1 injecting the step's event name alone, its data
    # dropped -> the chart takes copy_unnamed and no send is handed -> red
    test "delivers a step's event data as the injected event's payload" do
      event = %{"name" => "copy.available", "data" => %{"copy_id" => "c-1"}}

      assert Runner.run_case(data_case(event)) == :agree
    end

    # sabotage: event/1 giving every step the same fixed payload -> the
    # chart reaches notifying -> red
    test "a step without data injects an event with none" do
      assert {:disagree, message} = Runner.run_case(data_case(%{"name" => "copy.available"}))
      assert message =~ ~s|Expected active states ["notifying"], but got ["copy_unnamed"]|
    end
  end

  describe "run_case/1 with declared_events and expect_accepts" do
    @loan_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="on_loan">
        <state id="on_loan">
            <transition event="loan.renew" target="on_loan"/>
            <transition event="copy.returned" target="returned"/>
        </state>
        <final id="returned"/>
    </scxml>
    """

    defp accepts_case(host) do
      %{
        "id" => "statifier/accepts/loan",
        "source" => @loan_source,
        "description" => "",
        "initial_configuration" => ["on_loan"],
        "steps" => [],
        "host" => host
      }
    end

    @declared ["loan.renew", "loan.archived"]
    @expected %{"unreachable" => ["loan.archived"], "undeclared" => ["copy.returned"]}

    # sabotage: `accepts/2`'s comparing clause calling
    # `Statifier.Chart.check_accepts/2` with `nil` instead of the declared
    # names -> both lists come back empty -> red
    test "agrees when check_accepts/2 answers exactly the expected lists" do
      host = %{"declared_events" => @declared, "expect_accepts" => @expected}

      assert Runner.run_case(accepts_case(host)) == :agree
    end

    # sabotage: `accepts/2`'s comparing clause returning :ok without
    # comparing -> red
    test "disagrees when a list differs, stating both" do
      expected = %{@expected | "undeclared" => []}
      host = %{"declared_events" => @declared, "expect_accepts" => expected}

      assert {:disagree, message} = Runner.run_case(accepts_case(host))
      assert message =~ "Expected the accepts check"
      assert message =~ ~s|"undeclared":["copy.returned"]|
    end

    # sabotage: `accepts/2`'s comparing clause comparing the lists as sets
    # (`Enum.sort/1` on both sides) -> red
    test "compares each list's order too" do
      declared = ["loan.archived", "loan.lent"]
      expected = %{"unreachable" => ["loan.lent", "loan.archived"], "undeclared" => []}
      host = %{"declared_events" => declared ++ ["loan.renew", "copy.returned"]}

      assert {:disagree, _message} =
               Runner.run_case(accepts_case(Map.put(host, "expect_accepts", expected)))
    end

    # sabotage: `accepts/2`'s two half-present clauses deleted, so a half
    # falls through to `:ok` -> red
    test "disagrees when only one of the two keys is present" do
      assert {:disagree, "declared_events is present without expect_accepts"} =
               Runner.run_case(accepts_case(%{"declared_events" => @declared}))

      assert {:disagree, "expect_accepts is present without declared_events"} =
               Runner.run_case(accepts_case(%{"expect_accepts" => @expected}))
    end
  end

  describe "run/2's :after_steps option" do
    @hold_source """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="idle">
        <state id="idle">
            <transition event="copy.available" target="awaiting_pickup"/>
        </state>
        <state id="awaiting_pickup">
            <transition event="copy.collected" target="idle"/>
        </state>
    </scxml>
    """

    defp hold_case(host) do
      %{
        "id" => "statifier/diff/hold",
        "source" => @hold_source,
        "description" => "",
        "initial_configuration" => ["idle"],
        "steps" => [
          %{"event" => %{"name" => "copy.available"}, "configuration" => ["awaiting_pickup"]}
        ],
        "host" => host
      }
    end

    # sabotage: drive/4 calling the function before `steps/2` -> it sees
    # idle -> red
    test "calls the function once, with the settled state the last step left" do
      parent = self()

      after_steps = fn settled ->
        send(parent, {:settled, Statifier.active_leaf_states(settled)})
        :ok
      end

      assert HostCase.run(hold_case(%{}), after_steps: after_steps) == :agree
      assert_received {:settled, leaves}
      assert leaves == MapSet.new(["awaiting_pickup"])
      refute_received {:settled, _leaves}
    end

    # sabotage: drive/4 ignoring the function's answer -> red
    test "a disagreement the function answers is the case's" do
      after_steps = fn _settled -> {:disagree, "the position is not the expected one"} end

      assert HostCase.run(hold_case(%{}), after_steps: after_steps) ==
               {:disagree, "the position is not the expected one"}
    end

    # sabotage: run/2's default function answering a disagreement -> red
    test "runs a case carrying a diff pair like any other host case, with no function" do
      host = %{
        "to_source" => @hold_source,
        "expect_diff" => %{"class" => "identical", "reasons" => []},
        "expect_compatible_at" => true
      }

      assert HostCase.run(hold_case(host)) == :agree
    end
  end
end
