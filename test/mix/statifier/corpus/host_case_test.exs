defmodule Mix.Statifier.Corpus.HostCaseTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.Corpus.Runner

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
end
