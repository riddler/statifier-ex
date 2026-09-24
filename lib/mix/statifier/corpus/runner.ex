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

  A case carrying a `host` object runs through
  `Mix.Statifier.Corpus.HostCase` instead, which registers the case's send
  types with the session it starts and compares the sends handed to them
  with the case's `expect_sends` (ADR-0070 decision 5); when the `host`
  object carries `declared_events`, it also compares
  `Statifier.Chart.check_accepts/2`'s answer with the case's
  `expect_accepts` (ADR-0071 decision 7).
  """

  alias Mix.Statifier.Corpus.{Authored, HostCase}
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
  Runs the authored cases the regression ratchet names by `paths`, each
  path the case's JSON file (`Mix.Statifier.Corpus.Authored.case_path/1`),
  relative to `root` or already joined to it. Returns `{path, outcome}`
  pairs in the order given, reading every authored case under `root`
  once. A path that names no authored case disagrees, naming itself: the
  ratchet never passes a case it cannot find. A malformed case tree is
  refused as `Mix.Statifier.Corpus.Authored.read/1` refuses it.

  The caller starts the session runtime first (`start_runtime/0`), as for
  `run/1`.
  """
  @spec run_paths(paths :: [Path.t()], root :: Path.t()) ::
          {:ok, [{Path.t(), outcome()}]} | {:error, String.t()}
  def run_paths(paths, root) do
    with {:ok, cases} <- Authored.read(root) do
      by_path = Map.new(cases, &{Authored.case_path(&1), &1})
      named = Enum.map(paths, &{&1, Map.get(by_path, relative(&1, root))})
      found = for {_path, corpus_case} <- named, corpus_case != nil, do: corpus_case
      outcomes = found |> run() |> Map.new()

      {:ok,
       Enum.map(named, fn
         {path, nil} -> {path, {:disagree, "#{path} names no authored case"}}
         {path, corpus_case} -> {path, Map.fetch!(outcomes, corpus_case["id"])}
       end)}
    end
  end

  defp relative(path, "."), do: path
  defp relative(path, root), do: Path.relative_to(path, root)

  @doc """
  Starts the `:statifier` application and places `Statifier.Supervisor`,
  the session runtime a case using `<send>`, `<invoke>` or a delay runs
  through (ADR-0027: the library starts no processes of its own). Idempotent:
  a runtime already placed is left as it is.
  """
  @spec start_runtime() :: :ok
  def start_runtime do
    Mix.Task.run("app.start")

    case Statifier.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Runs one case through `Statifier.Testing.Case.test_scxml/4`, or through
  `Mix.Statifier.Corpus.HostCase.run/1` when it carries a `host` object.
  """
  @spec run_case(corpus_case :: map()) :: outcome()
  def run_case(%{"host" => _host} = corpus_case) do
    HostCase.run(corpus_case)
  rescue
    error -> {:disagree, error |> Exception.message() |> String.trim()}
  catch
    :exit, reason -> {:disagree, "exited: #{inspect(reason)}"}
  end

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
