defmodule Statifier.HostingWithoutSessionTest do
  @moduledoc """
  Pins the runnable minimal driver in `docs/hosting-without-session.md`: the
  chart, the `MyApp.Driver` module, and the two drives that guide walks
  through. The code here is the code printed in that guide - if one changes,
  change both.
  """

  use Statifier.Testing.Case, async: true

  alias Statifier.Event

  # The example chart from docs/hosting-without-session.md, verbatim: an
  # <onentry> that logs, arms a delayed send, and raises an immediate
  # self-send, then a top-level <final> the fired timer reaches.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
         datamodel="predicator" initial="idle">
      <state id="idle">
          <transition event="start" target="working"/>
      </state>
      <state id="working">
          <onentry>
              <log label="phase" expr="'working'"/>
              <send event="settle" delay="50ms"/>
              <send event="working.entered"/>
          </onentry>
          <transition event="working.entered" target="waiting"/>
      </state>
      <state id="waiting">
          <transition event="settle" target="settled"/>
      </state>
      <final id="settled"/>
  </scxml>
  """

  defmodule Driver do
    @moduledoc """
    The example driver from `docs/hosting-without-session.md`, verbatim (the
    guide names it `MyApp.Driver`). Not a supported API surface - it is the
    smallest honest thing that drives the pure core and performs what
    `Statifier.Session.Effects.plan/2` hands back.
    """

    alias Statifier.{Effect, Event, Interpreter, MachineState}
    alias Statifier.Session.Effects

    defstruct timers: [], logs: [], halted: nil

    @typedoc "What one drive accumulated for the host to act on."
    @type t :: %__MODULE__{
            timers: [{String.t() | nil, pos_integer(), non_neg_integer(), String.t()}],
            logs: [{String.t() | nil, term()}],
            halted: :done | :budget_exhausted | :not_running | nil
          }

    @typedoc "The reduce accumulator: the position, what the drive gathered, and events still to re-drive."
    @type acc :: {MachineState.t(), t(), [Event.t()]}

    @doc """
    Drives one external event, performs the instructions the plan returns,
    and re-drives whatever those instructions enqueued, until nothing is
    left to feed in.
    """
    @spec drive(machine_state :: MachineState.t(), event :: Event.t(), acc :: t()) ::
            {MachineState.t(), t()}
    def drive(machine_state, %Event{} = event, acc \\ %__MODULE__{}) do
      case Interpreter.handle_event(machine_state, event) do
        {:ok, machine_state, effects} ->
          effects
          |> Effects.plan(plan_context(machine_state))
          |> Enum.reduce({machine_state, acc, []}, &perform/2)
          |> drain()

        {:error, :not_running} ->
          {machine_state, %{acc | halted: :not_running}}
      end
    end

    @spec plan_context(machine_state :: MachineState.t()) :: Effects.context()
    defp plan_context(machine_state) do
      %{
        session_id: machine_state.datamodel["_sessionid"],
        invoke_types: machine_state.invoke_types,
        invoke_handlers: %{},
        invocation_types: %{}
      }
    end

    @spec perform(instruction :: Effects.instruction(), acc :: acc()) :: acc()
    defp perform({:enqueue_event, event}, {machine_state, acc, queued}),
      do: {machine_state, acc, queued ++ [event]}

    defp perform({:schedule, send_id, delay_ms, _route, event, effect}, {ms, acc, queued}) do
      {:send_delayed, delayed} = effect
      row = {send_id, delayed.ordinal, delay_ms, event.name}
      {ms, %{acc | timers: acc.timers ++ [row]}, queued}
    end

    defp perform({:cancel_timers, send_id}, {machine_state, acc, queued}) do
      kept = Enum.reject(acc.timers, &match?({^send_id, _ordinal, _delay, _name}, &1))
      {machine_state, %{acc | timers: kept}, queued}
    end

    defp perform({:notify, {:log, %Effect.Log{} = log}}, {machine_state, acc, queued}),
      do: {machine_state, %{acc | logs: acc.logs ++ [{log.label, log.value}]}, queued}

    defp perform({:halt, reason}, {machine_state, acc, queued}),
      do: {machine_state, %{acc | halted: reason}, queued}

    defp perform(_instruction, state), do: state

    @spec drain(acc :: acc()) :: {MachineState.t(), t()}
    defp drain({machine_state, acc, []}), do: {machine_state, acc}

    defp drain({machine_state, acc, [event | rest]}) do
      {machine_state, acc} = drive(machine_state, event, acc)
      drain({machine_state, acc, rest})
    end
  end

  # sabotage: drop the `{:enqueue_event, _}` arm from Driver.perform/2 -> the
  # self-send never re-enters and the chart stays in "working" -> red.
  test "the first drive lands in waiting, logging and arming one timer" do
    {:ok, machine} = Statifier.compile(@chart)
    {machine_state, _effects} = Statifier.Interpreter.initialize(machine)

    {machine_state, acc} = Driver.drive(machine_state, Event.external("start"))

    assert Statifier.active_leaf_states(machine_state) == MapSet.new(["waiting"])
    assert acc.logs == [{"phase", "working"}]
    assert [{_send_id, 1, 50, "settle"}] = acc.timers
    assert acc.halted == nil
  end

  # sabotage: drop the `{:halt, _}` arm from Driver.perform/2 -> the terminal
  # drive reports `halted: nil` -> red.
  test "the fired timer's drive reaches the final state and halts" do
    {:ok, machine} = Statifier.compile(@chart)
    {machine_state, _effects} = Statifier.Interpreter.initialize(machine)
    {machine_state, acc} = Driver.drive(machine_state, Event.external("start"))

    {machine_state, acc} = Driver.drive(machine_state, Event.external("settle"), acc)

    assert acc.halted == :done
    assert machine_state.status == :done
    assert Statifier.MachineState.internal_queue_empty?(machine_state)
  end
end
