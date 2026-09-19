defmodule Mix.Statifier.Corpus.Runner do
  @moduledoc """
  Runs corpus cases through statifier in the calling process's node, the way
  a generated test module runs them: each case is one call to
  `Statifier.Testing.Case.test_scxml/4` with the case's source, description,
  initial configuration and steps, so a case agrees exactly when its
  generated module would pass.

  `test_scxml/4` asserts that the active leaf states statifier produces equal
  the expected ones after initialization and after every step, so a case
  that agrees has configurations that are what statifier produced; a case
  that disagrees carries the assertion's own message. Cases run
  concurrently, as the generated modules do (`async: true`); a case needing
  a session (`<send>`, `<invoke>`, timers) needs the `:statifier`
  application started, which `mix statifier.corpus` does before it runs any.
  """

  alias Statifier.Testing.Case

  # Well above the harness's own 4s configuration deadline per step, so a
  # timeout here means a run that never returned, not a slow one.
  @timeout_ms 60_000

  @typedoc "What running one case found."
  @type outcome :: :agree | {:disagree, String.t()}

  @doc """
  Runs every case, returning `{id, outcome}` pairs in the order given.
  """
  @spec run(cases :: [map()]) :: [{String.t(), outcome()}]
  def run(cases) do
    cases
    |> Task.async_stream(&run_case/1,
      ordered: true,
      timeout: @timeout_ms,
      on_timeout: :kill_task,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.zip_with(cases, fn
      {:ok, outcome}, corpus_case ->
        {corpus_case["id"], outcome}

      {:exit, reason}, corpus_case ->
        {corpus_case["id"], {:disagree, "did not finish: #{inspect(reason)}"}}
    end)
  end

  @doc """
  Runs one case through `Statifier.Testing.Case.test_scxml/4`.
  """
  @spec run_case(corpus_case :: map()) :: outcome()
  def run_case(corpus_case) do
    steps = Enum.map(corpus_case["steps"], &{&1["event"], &1["configuration"]})

    :ok =
      Case.test_scxml(
        corpus_case["source"],
        corpus_case["description"],
        corpus_case["initial_configuration"],
        steps
      )

    :agree
  rescue
    error -> {:disagree, error |> Exception.message() |> String.trim()}
  catch
    :exit, reason -> {:disagree, "exited: #{inspect(reason)}"}
  end
end
