defmodule Mix.Statifier.Corpus.HostCase do
  @moduledoc """
  Runs a corpus case that carries a `host` object (ADR-0070 decision 5):
  the host registers the case's `send_types` (ADR-0069), and the sends
  handed to it must be the case's `expect_sends`.

  `Statifier.Testing.Case.test_scxml/4` starts its session with no
  registration, so a host case runs here instead, through the same public
  session API: `Statifier.start_session/2` with `:send_types` naming
  `Mix.Statifier.Corpus.HostCase.Processor` for every registered type,
  `Statifier.Session.send_event/2` for each step, and
  `Statifier.Session.status/1` and `Statifier.Session.snapshot/1` to wait
  for the chart to settle and read its active leaf states. The waiting
  follows `test_scxml/4`'s: a pending library timer is given a short window
  to fire before the next event, and a configuration is read once the
  session has had nothing queued and no timer pending on two consecutive
  polls, or the chart has left the running status, or a deadline passed.

  A case agrees when the active leaf states after initialization and after
  every step are the ones it expects, and the sends handed to the processor
  over the whole run, in order, are exactly its `expect_sends`. Each handed
  send is written in the case's language-neutral item shape: `type`,
  `target`, `event` with its `name` and, when the send carries a payload,
  its `data`; `delay_ms` for a delayed send; and `send_id` only when the
  author named the send, which is when the delivered event carries one.
  A registered delayed send is the host's timer, and this host never fires
  one.

  A host object may also carry `declared_events` and `expect_accepts`,
  present together or not at all (ADR-0071 decision 7). Before it starts the
  session, the runner calls `Statifier.Chart.check_accepts/2` on the compiled
  chart with `declared_events`, and the case agrees only when both lists it
  answers are exactly `expect_accepts`' `unreachable` and `undeclared`, order
  included. Either key without the other is a disagreement.
  """

  alias Mix.Statifier.Corpus.HostCase.Processor
  alias Statifier.{MachineState, Session}

  @settle_window_ms 100
  @configuration_deadline_ms 4_000
  @poll_interval_ms 5

  @doc """
  Runs one host case, returning `:agree` or `{:disagree, message}`.
  """
  @spec run(corpus_case :: map()) :: :agree | {:disagree, String.t()}
  def run(%{"source" => source, "host" => host} = corpus_case) do
    with {:ok, machine} <- compile(source),
         :ok <- accepts(machine, host) do
      session_id = MachineState.generate_session_id()
      :yes = :global.register_name({Processor, session_id}, self())

      send_types = Map.new(Map.get(host, "send_types", []), &{&1, Processor})

      {:ok, session} =
        Statifier.start_session(machine,
          session_id: session_id,
          send_types: send_types,
          subscribers: [self()]
        )

      try do
        drive(session, corpus_case, Map.get(host, "expect_sends", []))
      after
        Session.stop(session)
        :global.unregister_name({Processor, session_id})
      end
    end
  end

  defp compile(source) do
    case Statifier.compile(source) do
      {:ok, machine} -> {:ok, machine}
      {:error, errors} -> {:disagree, "the document did not compile: #{inspect(errors)}"}
    end
  end

  defp accepts(machine, %{"declared_events" => declared, "expect_accepts" => expected}) do
    actual = Statifier.Chart.check_accepts(machine, declared)
    actual = %{"unreachable" => actual.unreachable, "undeclared" => actual.undeclared}

    if actual == expected,
      do: :ok,
      else:
        {:disagree,
         "Expected the accepts check #{JSON.encode!(expected)}, " <>
           "but got #{JSON.encode!(actual)}"}
  end

  defp accepts(_machine, host) when is_map_key(host, "declared_events"),
    do: {:disagree, "declared_events is present without expect_accepts"}

  defp accepts(_machine, host) when is_map_key(host, "expect_accepts"),
    do: {:disagree, "expect_accepts is present without declared_events"}

  defp accepts(_machine, _host), do: :ok

  defp drive(session, corpus_case, expect_sends) do
    steps = Enum.map(corpus_case["steps"], &{&1["event"]["name"], &1["configuration"]})

    with :ok <- configuration(session, corpus_case["initial_configuration"]),
         :ok <- steps(session, steps) do
      handed(session, expect_sends)
    end
  end

  defp steps(session, steps) do
    Enum.reduce_while(steps, :ok, fn {name, expected}, :ok ->
      settle_short_timers(session, deadline(@settle_window_ms))
      :ok = Session.send_event(session, name)

      case configuration(session, expected) do
        :ok -> {:cont, :ok}
        disagree -> {:halt, disagree}
      end
    end)
  end

  defp handed(session, expect_sends) do
    # A status call returns after every instruction the session performed
    # before it, so every message the processor sent is already here.
    _status = Session.status(session)
    sends = collect([])

    if sends == expect_sends,
      do: :agree,
      else:
        {:disagree,
         "Expected the sends handed to the host #{JSON.encode!(expect_sends)}, " <>
           "but got #{JSON.encode!(sends)}"}
  end

  defp collect(acc) do
    receive do
      {Processor, {:deliver, effect, event}} -> collect([item(effect, event) | acc])
      {Processor, {:cancel, _cancel}} -> collect(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp item(effect, event) do
    event_map =
      if event.data in [:undefined, nil, %{}],
        do: %{"name" => event.name},
        else: %{"name" => event.name, "data" => event.data}

    %{"type" => effect.type, "target" => effect.target, "event" => event_map}
    |> put_present("delay_ms", Map.get(effect, :delay_ms))
    |> put_present("send_id", event.sendid)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp configuration(session, expected_ids) do
    expected = MapSet.new(expected_ids)
    observed = poll(session, expected, deadline(@configuration_deadline_ms), {false, nil})
    actual = Statifier.active_leaf_states(observed)

    cond do
      MapSet.size(MachineState.active_leaf_states(observed)) != MapSet.size(actual) ->
        {:disagree, "an active leaf state has no id, so the expectation cannot name it"}

      actual == expected ->
        :ok

      true ->
        {:disagree,
         "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"}
    end
  end

  # A terminated chart's configuration is empty by construction; the one it
  # held at exit rides the `{:done, _}` effect, as `test_scxml/4` reads it.
  # The effect arrives once, so a poll that drained it hands it to the next.
  defp poll(session, expected, deadline, {was_stable?, done}) do
    done = done_effect() || done
    observed = observed(Session.snapshot(session), done)
    stable? = stable?(Session.status(session))

    cond do
      Statifier.active_leaf_states(observed) == expected -> observed
      stable? and was_stable? -> observed
      System.monotonic_time(:millisecond) >= deadline -> observed
      true -> pause_then(fn -> poll(session, expected, deadline, {stable?, done}) end)
    end
  end

  defp observed(snapshot, {:done, effect}), do: %{snapshot | configuration: effect.configuration}
  defp observed(snapshot, nil), do: snapshot

  defp stable?(status),
    do: status.status != :running or (status.queued_events == 0 and status.pending_timers == 0)

  defp done_effect do
    receive do
      {:statifier, _session_id, {:effect, {:done, _done} = effect}} -> effect
    after
      0 -> nil
    end
  end

  defp settle_short_timers(session, deadline) do
    cond do
      Session.status(session).pending_timers == 0 -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :ok
      true -> pause_then(fn -> settle_short_timers(session, deadline) end)
    end
  end

  defp pause_then(fun) do
    Process.sleep(@poll_interval_ms)
    fun.()
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

defmodule Mix.Statifier.Corpus.HostCase.Processor do
  @moduledoc """
  The `Statifier.Send.Processor` a host case registers for every type in its
  `send_types`. Its planning callbacks return one `{:handler, ...}`
  instruction each; `perform/2` sends the payload to the process running
  the case, found by the session's id under `:global`, where
  `Mix.Statifier.Corpus.HostCase.run/1` registered it before starting the
  session.
  """

  @behaviour Statifier.Send.Processor

  @impl Statifier.Send.Processor
  @spec deliver(
          effect :: Statifier.Effect.Send.t() | Statifier.Effect.SendDelayed.t(),
          event :: Statifier.Event.t(),
          ctx :: Statifier.Send.Processor.ctx()
        ) :: {:ok, [{:handler, module(), term()}]}
  def deliver(effect, event, _ctx), do: {:ok, [{:handler, __MODULE__, {:deliver, effect, event}}]}

  @impl Statifier.Send.Processor
  @spec cancel(cancel :: Statifier.Effect.Cancel.t(), ctx :: Statifier.Send.Processor.ctx()) ::
          {:ok, [{:handler, module(), term()}]}
  def cancel(cancel, _ctx), do: {:ok, [{:handler, __MODULE__, {:cancel, cancel}}]}

  @impl Statifier.Send.Processor
  @spec perform(payload :: term(), ctx :: Statifier.Send.Processor.ctx()) :: :ok
  def perform(payload, %{session_id: session_id}) do
    case :global.whereis_name({__MODULE__, session_id}) do
      pid when is_pid(pid) -> send(pid, {__MODULE__, payload})
      :undefined -> :ok
    end

    :ok
  end
end
