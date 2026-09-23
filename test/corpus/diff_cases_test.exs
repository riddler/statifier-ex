defmodule Corpus.DiffCasesTest do
  # Not async: every case with a position expectation runs a session, and the
  # harness's settle windows are tuned for the corpus running as the
  # regression ratchet runs it, as in corpus_files_test.exs.
  use ExUnit.Case, async: false

  alias Mix.Statifier.Corpus.HostCase
  alias Statifier.{Chart, Position}

  # The diff pair and the position expectation a committed `statifier` case
  # carries in its host object (conformance/schema/case.json, ADR-0072),
  # compared here rather than by the corpus runner: nothing in lib/ calls
  # Statifier.Chart.diff/3 or the position predicate (ADR-0072 decision 6).
  # The cases are read from the committed corpus file, the one a sibling
  # implementation vendors; `mix statifier.corpus --check` keeps it equal to
  # the authored cases under conformance/cases/.

  @classes ~w(identical compatible mapped breaking)

  defp diff_cases do
    "conformance/corpus/statifier.json"
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("cases")
    |> Enum.filter(&Map.has_key?(&1["host"] || %{}, "to_source"))
  end

  defp compile!(source) do
    {:ok, machine} = Statifier.compile(source)
    machine
  end

  # What diff/3 answers for a case, in the JSON shape its expect_diff holds.
  defp diff_json(%{"source" => source, "host" => host}) do
    opts = if Map.has_key?(host, "mapping"), do: [mapping: host["mapping"]], else: []
    answer = Chart.diff(compile!(source), compile!(host["to_source"]), opts)

    %{
      "class" => Atom.to_string(answer.class),
      "reasons" => Enum.map(answer.reasons, &reason_json/1)
    }
  end

  defp reason_json({:state_nameless, index}),
    do: %{"reason" => "state_nameless", "index" => index}

  defp reason_json({:state_changed, id, fields}),
    do: %{
      "reason" => "state_changed",
      "state" => id,
      "fields" => Enum.map(fields, &Atom.to_string/1)
    }

  defp reason_json({:state_mapped, from_id, to_id}),
    do: %{"reason" => "state_mapped", "state" => from_id, "to_state" => to_id}

  defp reason_json({kind, id, t_index}) when kind in [:transition_removed, :transition_added],
    do: %{"reason" => Atom.to_string(kind), "state" => id, "t_index" => t_index}

  defp reason_json({kind, descriptor}) when kind in [:event_removed, :event_added],
    do: %{"reason" => Atom.to_string(kind), "descriptor" => descriptor}

  defp reason_json({kind, id}) when kind in [:data_removed, :data_added],
    do: %{"reason" => Atom.to_string(kind), "data_id" => id}

  defp reason_json({kind, id}), do: %{"reason" => Atom.to_string(kind), "state" => id}

  # Runs the case through the corpus runner, and at the position its steps
  # leave asks the predicate what the case expects it to answer. Each case
  # runs in a process of its own, as `Mix.Statifier.Corpus.Runner.run/1`
  # runs them: a case that disagrees before its sends are collected leaves
  # them in its process's mailbox, where the next case would read them.
  defp position_outcome(%{"source" => source, "host" => host} = corpus_case) do
    from = compile!(source)
    to = compile!(host["to_source"])
    expected = host["expect_compatible_at"]

    after_steps = fn settled ->
      {:ok, exported} = Position.export(settled)
      answer = Position.compatible_at?(from, to, exported)

      if answer == expected,
        do: :ok,
        else: {:disagree, "expected compatible_at #{expected}, but got #{answer}"}
    end

    fn -> HostCase.run(corpus_case, after_steps: after_steps) end
    |> Task.async()
    |> Task.await(60_000)
  end

  describe "the committed diff cases" do
    # sabotage: an expected reason list emptied in one authored case and the
    # corpus re-emitted -> red, naming that case (recorded in the pull
    # request that added these cases)
    test "each answers the class and reasons its expect_diff states, in order" do
      mismatches =
        for corpus_case <- diff_cases(),
            actual = diff_json(corpus_case),
            actual != corpus_case["host"]["expect_diff"],
            do: {corpus_case["id"], actual}

      assert mismatches == []
    end

    # sabotage: the predicate expectation of statifier/diff/
    # hold_waiting_through_an_idle_edit flipped to false and the corpus
    # re-emitted -> red
    test "each answers its expect_compatible_at at the position its steps leave" do
      outcomes =
        for corpus_case <- diff_cases(),
            Map.has_key?(corpus_case["host"], "expect_compatible_at"),
            do: {corpus_case["id"], position_outcome(corpus_case)}

      assert outcomes != []
      assert Enum.reject(outcomes, &match?({_id, :agree}, &1)) == []
    end

    # sabotage: n/a - asserts the committed case set, no lib/ behavior;
    # the predicate expectation of statifier/diff/
    # hold_waiting_through_an_idle_edit flipped to false -> red, no true left
    test "hold one pair per class and the predicate's true and false answers" do
      cases = diff_cases()
      classes = Enum.map(cases, & &1["host"]["expect_diff"]["class"])

      assert Enum.sort(Enum.uniq(classes)) == Enum.sort(@classes)
      assert Enum.all?(cases, &(&1["spec"] == "diff"))

      answers =
        for corpus_case <- cases,
            Map.has_key?(corpus_case["host"], "expect_compatible_at"),
            uniq: true,
            do: corpus_case["host"]["expect_compatible_at"]

      assert Enum.sort(answers) == [false, true]
    end
  end
end
