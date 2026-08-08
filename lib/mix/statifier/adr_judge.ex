defmodule Mix.Statifier.AdrJudge do
  @moduledoc """
  Judges the current branch's diff against ADR-0012 (debuggability designed
  into the core) using two independent model calls: one proposes violations,
  a second is prompted to refute each one. Only a proposed violation the
  refute pass fails to overturn becomes a finding - a single pass reporting
  whatever it first notices is exactly what the adversarial-verification
  requirement on this check rules out, because a false positive here blocks
  a commit (CLAUDE.md: "never go green by weakening the check" means the fix
  for a bad finding has to be "the check was wrong," not "disable the
  check" - so the bar to reach gate-failure status is higher than an FYI).

  `analyze/2` is pure given a diff plus ADR text and an `opts[:caller]` (a
  function from a prompt string to a `{:ok, response} | {:error, reason}`
  tuple; real calls shell out to the `claude` CLI in production via
  `call_claude_cli/1`, a stub in tests). `collect/1` gathers that source the
  same way `Mix.Statifier.GateGuard` and `Mix.Statifier.AdrGuard` do, plus two
  checks those guards do not need: whether the `claude` CLI is on `PATH`,
  checked before any git call runs (there is no point diffing if the stage
  cannot call out), and whether the diff touches `lib/statifier/` at all.

  Local-only by design, and now purely so: `call_claude_cli/1` shells out to
  the developer's own `claude` CLI (`System.cmd/3`) rather than calling the
  Anthropic API directly, so the stage rides the developer's existing Claude
  Code auth instead of needing its own `ANTHROPIC_API_KEY`. `--tools ""` and
  `--strict-mcp-config` keep the call a single non-agentic completion - no
  tool access, no MCP servers - so the judge can only read the prompt this
  module built, never the repository on its own.

  Every parse failure or ambiguous model response fails closed rather than
  raising: an unparseable propose response yields no candidates, and an
  unparseable or ambiguous refute response is read as "not a violation" -
  the same tie-break the refute pass uses on a clear verdict. A candidate
  survives only when the refute pass explicitly says it does.
  """

  @type finding :: %{
          file: String.t(),
          line: pos_integer() | nil,
          severity: String.t(),
          check: String.t(),
          message: String.t()
        }

  @type source :: %{diff: String.t(), adr_text: String.t()}
  @type caller :: (String.t() -> {:ok, String.t()} | {:error, term()})
  @type candidate :: %{file: String.t(), line: pos_integer() | nil, claim: String.t()}

  @core_prefix "lib/statifier/"
  @adr_path "docs/adr/0012-debuggability-designed-into-the-core.md"
  @cli_name "claude"
  @default_model "claude-haiku-4-5-20251001"
  @model_env "STATIFIER_ADR_JUDGE_MODEL"

  # st-c8c: with `claude` on PATH and an in-scope dirty tree, a test that
  # forgets to inject `opts[:caller]` makes real CLI calls - measured at ~2
  # minutes of gate time per run (the Tests stage and the Regression ratchet
  # each run the suite) plus real spend. Every judged scope added since makes
  # that easier to trip into, so the test build has no reachable real caller
  # at all: the failure is a raise naming the omission, not a bill.
  @default_caller if Mix.env() == :test,
                    do: &__MODULE__.refuse_real_call/1,
                    else: &__MODULE__.call_claude_cli/1

  # Pinned because `diff.mnemonicPrefix` in a developer's git config would
  # otherwise rename the prefixes out from under the parser.
  @diff_flags ["--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]

  @doc """
  Turns a diff plus ADR-0012's text into adversarially-verified findings.

  `opts[:caller]` defaults to `call_claude_cli/1`, a real shell-out to the
  `claude` CLI, in every build except `:test` - there it defaults to
  `refuse_real_call/1`, which raises. Tests always inject a stub caller
  anyway, since this is the one seam the whole module exists to keep pure;
  the `:test` default exists as a backstop for a test that forgets to.
  """
  @spec analyze(source :: source(), opts :: keyword()) :: [finding()]
  def analyze(source, opts \\ []) do
    caller = Keyword.get(opts, :caller, @default_caller)
    chunks = core_chunks(source.diff)

    source.adr_text
    |> propose(chunks, caller)
    |> Enum.filter(&survives_refute?(&1, source.adr_text, caller))
    |> Enum.map(&to_finding/1)
  end

  @doc """
  Reads the diff, and ADR-0012's text, the judge needs.

  Checked in order: `opts[:cli_available]` (falling back to
  `System.find_executable/1`) first, since there is nothing to gain from
  touching git when the stage has no way to call out; then base-ref
  resolution (`opts[:base]`, then `origin/main`, then `main`), mirroring
  `Mix.Statifier.AdrGuard`; then whether the diff touches `lib/statifier/` at
  all. Each unmet condition returns its own atom so the task can report a
  distinct skip reason instead of a single opaque one.

  `opts[:runner]` replaces the `git` shell-out with a function of an argument
  list returning `{output, status}`, mirroring `Mix.Statifier.AdrGuard`.
  """
  @spec collect(opts :: keyword()) ::
          {:ok, source()} | {:error, String.t()} | :no_base_ref | :no_cli | :no_core_changes
  def collect(opts) do
    case cli_available?(opts) do
      false -> :no_cli
      true -> collect_with_cli(opts)
    end
  end

  defp cli_available?(opts) do
    Keyword.get_lazy(opts, :cli_available, fn -> System.find_executable(@cli_name) != nil end)
  end

  defp collect_with_cli(opts) do
    runner = Keyword.get(opts, :runner, &git/1)
    candidates = Enum.reject([opts[:base], "origin/main", "main"], &is_nil/1)

    case Enum.find(candidates, &resolves?(&1, runner)) do
      nil -> :no_base_ref
      ref -> collect_from(ref, runner, opts)
    end
  end

  defp collect_from(ref, runner, opts) do
    with {:ok, base} <- run(runner, ["merge-base", ref, "HEAD"]),
         base = String.trim(base),
         {:ok, diff} <- run(runner, ["diff", base | @diff_flags]) do
      full_diff = diff <> untracked_diff(runner)

      if core_chunks(full_diff) == [] do
        :no_core_changes
      else
        {:ok, %{diff: full_diff, adr_text: adr_text(opts)}}
      end
    end
  end

  defp adr_text(opts) do
    Keyword.get_lazy(opts, :adr_text, fn ->
      case File.read(@adr_path) do
        {:ok, content} -> content
        {:error, reason} -> "(unable to read #{@adr_path}: #{inspect(reason)})"
      end
    end)
  end

  # A file git has never seen is absent from `git diff` entirely, so a
  # brand-new interpreter module would be invisible to this check.
  defp untracked_diff(runner) do
    case run(runner, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, @core_prefix))
        |> Enum.map_join(&added_file_diff(runner, &1))

      {:error, _reason} ->
        ""
    end
  end

  # `git diff --no-index` exits 1 when the files differ, which is every call here.
  defp added_file_diff(runner, path) do
    case runner.(["diff", "--no-index" | @diff_flags] ++ ["/dev/null", path]) do
      {output, status} when status in [0, 1] -> output
      _other -> ""
    end
  end

  defp resolves?(ref, runner) do
    match?({:ok, _output}, run(runner, ["rev-parse", "--verify", "--quiet", ref]))
  end

  defp run(runner, args) do
    case runner.(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "git #{Enum.join(args, " ")} exited #{status}: #{output}"}
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  # -- diff scoping -----------------------------------------------------------

  # `{path, chunk}` per file the diff touches, `chunk` being that file's raw
  # unified-diff text (context, removals and additions alike) - unlike the
  # mechanical guards, an ADR-0012 violation is as likely to be a *removed*
  # trace call as an added one, so an added-lines-only view would miss it.
  @spec core_chunks(diff :: String.t()) :: [{String.t(), String.t()}]
  def core_chunks(diff) do
    diff
    |> file_chunks()
    |> Enum.filter(fn {path, _chunk} -> String.starts_with?(path, @core_prefix) end)
  end

  defp file_chunks(diff) do
    diff
    |> String.split(~r/^diff --git .*$/m, trim: true)
    |> Enum.map(&chunk_with_path/1)
    |> Enum.reject(&is_nil/1)
  end

  defp chunk_with_path(chunk) do
    case chunk_path(chunk) do
      nil -> nil
      path -> {path, chunk}
    end
  end

  defp chunk_path(chunk) do
    case Regex.run(~r/^\+\+\+ b\/(.+)$/m, chunk) do
      [_all, path] ->
        path

      nil ->
        case Regex.run(~r/^--- a\/(.+)$/m, chunk) do
          [_all, path] -> path
          nil -> nil
        end
    end
  end

  # -- propose / refute --------------------------------------------------------

  defp propose(adr_text, chunks, caller) do
    case caller.(propose_prompt(adr_text, chunks)) do
      {:ok, text} -> parse_propose(text)
      {:error, _reason} -> []
      _other -> []
    end
  end

  defp survives_refute?(candidate, adr_text, caller) do
    case caller.(refute_prompt(adr_text, candidate)) do
      {:ok, text} -> parse_refute(text)
      {:error, _reason} -> false
      _other -> false
    end
  end

  defp propose_prompt(adr_text, chunks) do
    hunks_text = Enum.map_join(chunks, "\n\n", fn {path, chunk} -> "### #{path}\n#{chunk}" end)

    """
    PROPOSE PASS

    You have no tool access in this session: do not attempt to read, grep, or
    list any file. Judge only from the ADR text and diff hunks given below -
    they are everything you get.

    You are reviewing a code change against ADR-0012 (debuggability designed
    into the core). Read the full ADR text and the diff hunks below, and list
    any changes that likely violate it: a microstep-resumability regression, a
    dropped trace effect at a phase boundary, a lost source location, or an
    uncounted or unstamped step.

    ADR-0012 full text:
    #{adr_text}

    Diff hunks touching lib/statifier/:
    #{hunks_text}

    Respond with JSON only, no other text: a list of candidate violations,
    each an object with "file", "line", and "claim" (one sentence). Respond
    with [] if you find none.
    """
  end

  defp refute_prompt(adr_text, candidate) do
    """
    REFUTE PASS

    You have no tool access in this session: do not attempt to read, grep, or
    list any file. Judge only from the ADR text and the candidate claim given
    below - they are everything you get.

    You are adversarially reviewing a claimed ADR-0012 violation. Argue
    against it being a real violation if a good-faith argument exists. Only
    conclude it survives if you cannot construct that argument.

    ADR-0012 full text:
    #{adr_text}

    Candidate claim:
    file: #{candidate.file}
    line: #{candidate.line}
    claim: #{candidate.claim}

    Respond with JSON only, no other text: {"violation": true} if the claim
    survives your challenge as a genuine ADR-0012 violation, or
    {"violation": false} if you have overturned it. If you are genuinely
    uncertain, respond {"violation": false} - ties go to "not a violation".
    """
  end

  defp parse_propose(text) do
    case text |> extract_json() |> JSON.decode() do
      {:ok, list} when is_list(list) -> Enum.flat_map(list, &normalize_candidate/1)
      _other -> []
    end
  end

  defp normalize_candidate(%{"file" => file, "claim" => claim} = candidate)
       when is_binary(file) and is_binary(claim) do
    [%{file: file, line: normalize_line(candidate["line"]), claim: claim}]
  end

  defp normalize_candidate(_other), do: []

  defp normalize_line(line) when is_integer(line), do: line
  defp normalize_line(_other), do: nil

  # An ambiguous or unparseable verdict reads as "not a violation" - refute
  # wins the tie, matching the explicit-verdict default the prompt states.
  defp parse_refute(text) do
    case text |> extract_json() |> JSON.decode() do
      {:ok, %{"violation" => true}} -> true
      _other -> false
    end
  end

  # "Respond with JSON only" is a request, not an enforced response format:
  # the `claude` CLI, unlike a direct Messages API call, routinely answers
  # with a prose preamble - sometimes several hallucinated tool-call or shell
  # code fences, since the model does not always notice it has been given no
  # tools (the prompt tells it so, but not every response listens) - and puts
  # the actual JSON verdict in its own fenced block only at the end. Anchoring
  # a fence strip to the start/end of the whole response only strips a fence
  # that already has nothing before or after it, which is the one case that
  # does not need help: `JSON.decode/1` fails on the leftover prose either
  # way, and both parse functions read that failure identically to a real
  # "no candidates" / "not a violation" - so a genuine verdict buried in
  # prose would silently vanish rather than surviving, which for the refute
  # pass in particular is a false negative in the safe direction (it costs a
  # finding, not causes one) but is still real signal being thrown away.
  # Scanning for every fenced block and taking the last one, rather than the
  # first, is deliberate: a rambling response's earlier fences are shell
  # commands it imagined running, and the verdict - if it gives one at all -
  # comes after them. Falling back to the trimmed response when there is no
  # fence at all keeps a plain, unfenced reply working too.
  defp extract_json(text) do
    case Regex.scan(~r/```(?:json)?\s*\n?(.*?)```/s, text) do
      [] -> String.trim(text)
      matches -> matches |> List.last() |> Enum.at(1) |> String.trim()
    end
  end

  defp to_finding(candidate) do
    %{
      file: candidate.file,
      line: candidate.line,
      severity: "error",
      check: "adr-0012-debuggability",
      message: candidate.claim
    }
  end

  # -- production caller --------------------------------------------------------

  @doc """
  The `:test`-build default `opts[:caller]`: raises instead of shelling out.

  Every test in this suite injects its own `opts[:caller]` stub; a test that
  forgets to is a bug, and the fix is to inject one, not to make a real
  `claude` CLI call and a real charge on that test's behalf. See the
  `@default_caller` moduledoc comment (st-c8c) for the incident this guards
  against.
  """
  @spec refuse_real_call(prompt :: String.t()) :: no_return()
  def refuse_real_call(_prompt) do
    raise """
    Mix.Statifier.AdrJudge.analyze/2 was called with no opts[:caller] in a \
    :test build. The default caller in :test refuses to shell out to the \
    real `claude` CLI - inject a stub via opts[:caller] instead.\
    """
  end

  @doc """
  The default `opts[:caller]`: one non-agentic `claude` CLI completion.

  `--tools ""` and `--strict-mcp-config` strip every tool and MCP server from
  the child session, so the prompt this module built is the only thing the
  call can see - no reading the repository, no reaching out on its own.
  `--output-format json` makes the reply parseable instead of scraping
  terminal prose, and `--model` carries `STATIFIER_ADR_JUDGE_MODEL` (falling
  back to the haiku default) the same way the direct-API version did.

  Only its shell-out half is unexercised by the test suite; every test
  injects its own `caller`, so this is the only place in the module that
  spawns a process. `parse_cli_response/1`, the half that turns the CLI's
  stdout into this function's return value, is pure and directly tested.
  """
  @spec call_claude_cli(prompt :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def call_claude_cli(prompt) do
    model = System.get_env(@model_env, @default_model)

    args = [
      "-p",
      prompt,
      "--output-format",
      "json",
      "--tools",
      "",
      "--strict-mcp-config",
      "--model",
      model
    ]

    case System.cmd(@cli_name, args, stderr_to_stdout: false) do
      {output, 0} -> parse_cli_response(output)
      {output, status} -> {:error, "claude CLI exited #{status}: #{output}"}
    end
  end

  @doc """
  Turns `claude --output-format json`'s stdout into `call_claude_cli/1`'s
  return value.

  The CLI prints a JSON array of stream events; the one this cares about has
  `"type": "result"`, and `"is_error": false` is the only shape read as
  success - anything else (a malformed array, no `result` event, an error
  result) fails closed to `{:error, _}` rather than guessing at partial text.
  Pure and directly testable with a fabricated array - no real CLI needed to
  exercise it.
  """
  @spec parse_cli_response(output :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_cli_response(output) do
    with {:ok, events} <- JSON.decode(output),
         %{"is_error" => false, "result" => text} <- find_result(events) do
      {:ok, text}
    else
      _other -> {:error, "claude CLI returned an unparseable or error result: #{inspect(output)}"}
    end
  end

  defp find_result(events) when is_list(events) do
    Enum.find(events, %{}, &(&1["type"] == "result"))
  end

  defp find_result(_other), do: %{}
end
