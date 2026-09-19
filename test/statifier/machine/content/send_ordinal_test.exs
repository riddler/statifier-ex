defmodule Statifier.Machine.Content.SendOrdinalTest do
  use ExUnit.Case, async: true

  # The ADR-0059 decision 5 Amendment of 2026-09-19 at the pure core: an
  # immediate `%Effect.Send{}` of a registered type (ADR-0069) carries
  # `ordinal`, read off `timer_counter`; a built-in one carries `nil` and
  # advances no counter. Driven through `Statifier.Interpreter.initialize/2`
  # with no session.

  alias Statifier.Effect.{Send, SendDelayed}
  alias Statifier.Interpreter
  alias Statifier.Send.Types

  # One author-written id inside a `<foreach>`: every iteration's effect
  # shares its send id, position counters, `c_index` and `owner`.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="joining">
      <datamodel>
          <data id="impressions" expr="['imp-1', 'imp-2', 'imp-3']"/>
          <data id="impression"/>
      </datamodel>
      <state id="joining">
          <onentry>
              <foreach array="impressions" item="impression">
                  <send type="TYPE" target="TARGET" event="impression.joined" id="joined">
                      <param name="impression_id" expr="impression"/>
                  </send>
              </foreach>
              <send type="TYPE" target="TARGET" event="reminder" delay="5s"/>
          </onentry>
      </state>
  </scxml>
  """

  @registered %{"myapp:sink" => __MODULE__}

  defp initialize(type, send_types) do
    target =
      if send_types == %{} or type == "scxml", do: "#_scxml_sess_joined", else: "joined_records"

    {:ok, machine} =
      @chart
      |> String.replace("TYPE", type)
      |> String.replace("TARGET", target)
      |> Statifier.compile()

    Interpreter.initialize(machine, send_types: Types.from_send_types(send_types))
  end

  defp sends(effects), do: for({:send, %Send{} = send} <- effects, do: send)
  defp delayed(effects), do: for({:send_delayed, %SendDelayed{} = send} <- effects, do: send)

  describe "a registered-type immediate send" do
    # sabotage: `dispatch_or_reject/8`'s `advance_timer_counter/2` call
    # passes `delay_ms != nil` alone (the registered arm dropped) -> the
    # counter never moves for an immediate send, every ordinal reads `0`, and
    # the `[1, 2, 3]` match reddens. Confirmed red and reverted.
    test "carries an ordinal, distinct across <foreach> iterations" do
      {machine_state, effects} = initialize("myapp:sink", @registered)

      assert [%Send{send_id: "joined"} = first | _rest] = sends(effects)
      assert Enum.map(sends(effects), & &1.ordinal) == [1, 2, 3]

      assert Enum.uniq(Enum.map(sends(effects), &{&1.send_id, &1.c_index, &1.owner})) ==
               [{first.send_id, first.c_index, first.owner}]

      # One shared sequence: the delayed send that follows reads the next value.
      assert [%SendDelayed{ordinal: 4}] = delayed(effects)
      assert machine_state.timer_counter == 4
    end
  end

  describe "a built-in immediate send" do
    # sabotage: `fields`' `:ordinal` is `machine_state.timer_counter`
    # unconditionally (the `registered?` gate dropped) -> a built-in send
    # carries the counter's value and the `nil` match reddens. Confirmed red
    # and reverted.
    test "carries a nil ordinal and advances no counter" do
      {machine_state, effects} = initialize("scxml", %{})

      assert [_first, _second, _third] = sends(effects)
      assert Enum.all?(sends(effects), &(&1.ordinal == nil))

      # The delayed send is the only effect that advanced the counter.
      assert [%SendDelayed{ordinal: 1}] = delayed(effects)
      assert machine_state.timer_counter == 1
    end

    # sabotage: `advance_timer_counter/2`'s `false` clause increments too ->
    # the counter reads `4` and the `1` match reddens. Confirmed red and
    # reverted.
    test "reads the same with a registered set that does not name it" do
      {machine_state, effects} = initialize("scxml", @registered)

      assert Enum.all?(sends(effects), &(&1.ordinal == nil))
      assert machine_state.timer_counter == 1
    end
  end
end
