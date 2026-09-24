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

  An `expect_sends` item may carry an `outcome` the runner performs or
  observes for that send (ADR-0070's 2026-09-23 Amendment). With
  `"fail"`, the runner reports the send handed at that item's position
  through `Statifier.Session.failed_send/3` as soon as it reads the
  processor's message, before it reads the next configuration, so the
  step that led to the send is the one whose configuration shows what
  the sender made of the `error.communication` it got. With
  `"cancelled"`, a `<cancel>` naming the send must reach the processor
  after it was handed the send: when a cancel reaches the processor, the
  runner writes `"outcome": "cancelled"` on each delayed send handed
  before it under the cancel's send id, generated or not, whose item
  asks for it, so the comparison above refuses a marked item no cancel
  reached. An item with no `outcome` claims nothing about a cancel: a
  cancel naming its send is not compared.

  A host object may also carry `declared_events` and `expect_accepts`,
  present together or not at all (ADR-0071 decision 7). Before it starts the
  session, the runner calls `Statifier.Chart.check_accepts/2` on the compiled
  chart with `declared_events`, and the case agrees only when both lists it
  answers are exactly `expect_accepts`' `unreachable` and `undeclared`, order
  included. Either key without the other is a disagreement.

  A host object may carry a diff pair as well - `to_source` and
  `expect_diff`, with an optional `mapping` and `expect_compatible_at`
  (ADR-0072, `conformance/schema/case.json`) - and this runner compares
  none of them: it runs such a case like any other host case. Nothing in
  `lib/` calls the chart diff or the position predicate (ADR-0072
  decision 6), so the test suite compares those four keys
  (`test/corpus/diff_cases_test.exs`), through `run/2`'s `:after_steps`
  option for the position the steps leave.
  """

  alias Mix.Statifier.Corpus.HostCase.Processor
  alias Statifier.{MachineState, Session}

  @settle_window_ms 100
  @configuration_deadline_ms 4_000
  @poll_interval_ms 5

  @doc """
  Runs one host case, returning `:agree` or `{:disagree, message}`.

  `opts` takes `:after_steps`, a function the runner calls once, after the
  last step's configuration agrees and before it compares the handed sends,
  with the session's settled `Statifier.MachineState`; it answers `:ok` or
  `{:disagree, message}`, and a disagreement is the case's. A case that
  disagrees before the sends are compared leaves them in the calling
  process's mailbox, so each run belongs in a process of its own, as
  `Mix.Statifier.Corpus.Runner.run/1` gives it.
  """
  @spec run(
          corpus_case :: map(),
          opts :: [after_steps: (MachineState.t() -> :ok | {:disagree, String.t()})]
        ) :: :agree | {:disagree, String.t()}
  def run(%{"source" => source, "host" => host} = corpus_case, opts \\ []) do
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
        after_steps = Keyword.get(opts, :after_steps, fn _settled -> :ok end)
        drive(session, corpus_case, Map.get(host, "expect_sends", []), after_steps)
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

  # `host` carries the case's `expect_sends` and the sends handed so far,
  # newest first, each as `{send_id, expected_item, item}`.
  defp drive(session, corpus_case, expect_sends, after_steps) do
    steps = Enum.map(corpus_case["steps"], &{&1["event"]["name"], &1["configuration"]})
    host = %{expect: expect_sends, handed: []}

    with {:ok, host} <- configuration(session, corpus_case["initial_configuration"], host),
         {:ok, host} <- steps(session, steps, host),
         :ok <- after_steps.(Session.snapshot(session)) do
      handed(session, host)
    end
  end

  defp steps(session, steps, host) do
    Enum.reduce_while(steps, {:ok, host}, fn {name, expected}, {:ok, host} ->
      settle_short_timers(session, deadline(@settle_window_ms))
      :ok = Session.send_event(session, name)

      case configuration(session, expected, host) do
        {:ok, host} -> {:cont, {:ok, host}}
        disagree -> {:halt, disagree}
      end
    end)
  end

  defp handed(session, host) do
    # A status call returns after every instruction the session performed
    # before it, so every message the processor sent is already here.
    _status = Session.status(session)
    {host, _reported?} = pump(session, host)
    sends = host.handed |> Enum.reverse() |> Enum.map(&elem(&1, 2))

    if sends == host.expect,
      do: :agree,
      else:
        {:disagree,
         "Expected the sends handed to the host #{JSON.encode!(host.expect)}, " <>
           "but got #{JSON.encode!(sends)}"}
  end

  # Reads every message the processor has sent so far into `host.handed`.
  # A handed send whose expected item, at the same position, carries
  # `"outcome": "fail"` is reported through `Statifier.Session.failed_send/3`
  # here, and `reported?` says one was, so the caller reads the
  # configuration again. A cancel marks the delayed sends it names whose
  # expected item says `"cancelled"`.
  defp pump(session, host, reported? \\ false) do
    receive do
      {Processor, {:deliver, effect, event}} ->
        expected = Enum.at(host.expect, length(host.handed))
        {item, failed?} = perform_outcome(session, effect, item(effect, event), expected)

        pump(
          session,
          %{host | handed: [{effect.send_id, expected, item} | host.handed]},
          reported? or failed?
        )

      {Processor, {:cancel, cancel}} ->
        pump(session, %{host | handed: cancel_named(host.handed, cancel.send_id)}, reported?)
    after
      0 -> {host, reported?}
    end
  end

  defp perform_outcome(session, effect, item, %{"outcome" => "fail"}) do
    :ok = Session.failed_send(session, effect)
    {Map.put(item, "outcome", "fail"), true}
  end

  defp perform_outcome(_session, _effect, item, _expected), do: {item, false}

  # A cancel reaches a processor only for a delayed send it was handed
  # under the cancel's id (`Statifier.Send.Processor`'s "What `cancel/2` is
  # handed"), so only delayed items are marked, and only those whose
  # expected item makes the claim.
  defp cancel_named(handed, send_id) do
    Enum.map(handed, fn
      {^send_id, %{"outcome" => "cancelled"} = expected, %{"delay_ms" => _delay} = item} ->
        {send_id, expected, Map.put(item, "outcome", "cancelled")}

      other ->
        other
    end)
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

  defp configuration(session, expected_ids, host) do
    expected = MapSet.new(expected_ids)

    {observed, host} =
      poll(session, expected, deadline(@configuration_deadline_ms), {false, nil}, host)

    actual = Statifier.active_leaf_states(observed)

    cond do
      MapSet.size(MachineState.active_leaf_states(observed)) != MapSet.size(actual) ->
        {:disagree, "an active leaf state has no id, so the expectation cannot name it"}

      actual == expected ->
        {:ok, host}

      true ->
        {:disagree,
         "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"}
    end
  end

  # A terminated chart's configuration is empty by construction; the one it
  # held at exit rides the `{:done, _}` effect, as `test_scxml/4` reads it.
  # The effect arrives once, so a poll that drained it hands it to the next.
  # The processor's messages are read after the snapshot and the status
  # call, so every send the session performed before them is read; a
  # failure reported then is on the session's queue ahead of the next
  # snapshot, so the snapshot just taken is stale and the poll goes round.
  defp poll(session, expected, deadline, {was_stable?, done}, host) do
    done = done_effect() || done
    observed = observed(Session.snapshot(session), done)
    stable? = stable?(Session.status(session))
    {host, reported?} = pump(session, host)
    again = fn -> poll(session, expected, deadline, {stable? and not reported?, done}, host) end

    cond do
      reported? -> again.()
      Statifier.active_leaf_states(observed) == expected -> {observed, host}
      stable? and was_stable? -> {observed, host}
      System.monotonic_time(:millisecond) >= deadline -> {observed, host}
      true -> pause_then(again)
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
