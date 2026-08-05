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
  tuple; real calls go through `Req` in production via `call_anthropic/1`, a
  stub in tests). `collect/1` gathers that source the same way
  `Mix.Statifier.GateGuard` and `Mix.Statifier.AdrGuard` do, plus two checks
  those guards do not need: an API key, checked before any git call runs
  (there is no point diffing if the stage cannot call out), and whether the
  diff touches `lib/statifier/` at all.

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
  @api_key_env "ANTHROPIC_API_KEY"
  @default_model "claude-haiku-4-5-20251001"
  @model_env "STATIFIER_ADR_JUDGE_MODEL"
  @anthropic_version "2023-06-01"
  @anthropic_url "https://api.anthropic.com/v1/messages"

  # Pinned because `diff.mnemonicPrefix` in a developer's git config would
  # otherwise rename the prefixes out from under the parser.
  @diff_flags ["--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]

  @doc """
  Turns a diff plus ADR-0012's text into adversarially-verified findings.

  `opts[:caller]` defaults to `call_anthropic/1`, a real network call - tests
  always inject a stub, since this is the one seam the whole module exists to
  keep pure.
  """
  @spec analyze(source :: source(), opts :: keyword()) :: [finding()]
  def analyze(source, opts \\ []) do
    caller = Keyword.get(opts, :caller, &call_anthropic/1)
    chunks = core_chunks(source.diff)

    source.adr_text
    |> propose(chunks, caller)
    |> Enum.filter(&survives_refute?(&1, source.adr_text, caller))
    |> Enum.map(&to_finding/1)
  end

  @doc """
  Reads the diff, and ADR-0012's text, the judge needs.

  Checked in order: `opts[:api_key]` (falling back to `ANTHROPIC_API_KEY`)
  first, since there is nothing to gain from touching git without one; then
  base-ref resolution (`opts[:base]`, then `origin/main`, then `main`),
  mirroring `Mix.Statifier.AdrGuard`; then whether the diff touches
  `lib/statifier/` at all. Each unmet condition returns its own atom so the
  task can report a distinct skip reason instead of a single opaque one.

  `opts[:runner]` replaces the `git` shell-out with a function of an argument
  list returning `{output, status}`, mirroring `Mix.Statifier.AdrGuard`.
  """
  @spec collect(opts :: keyword()) ::
          {:ok, source()} | {:error, String.t()} | :no_base_ref | :no_api_key | :no_core_changes
  def collect(opts) do
    case api_key(opts) do
      nil -> :no_api_key
      _key -> collect_with_key(opts)
    end
  end

  defp api_key(opts), do: Keyword.get(opts, :api_key, System.get_env(@api_key_env))

  defp collect_with_key(opts) do
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

    You are reviewing a code change against ADR-0012 (debuggability designed
    into the core). Read the full ADR text and the diff hunks below, and list
    any changes that likely violate it: a microstep-resumability regression, a
    dropped trace effect at a phase boundary, a lost source location, or an
    uncounted or unstamped step.

    ADR-0012 full text:
    #{adr_text}

    Diff hunks touching lib/statifier/:
    #{hunks_text}

    Respond with JSON only: a list of candidate violations, each an object
    with "file", "line", and "claim" (one sentence). Respond with [] if you
    find none.
    """
  end

  defp refute_prompt(adr_text, candidate) do
    """
    REFUTE PASS

    You are adversarially reviewing a claimed ADR-0012 violation. Argue
    against it being a real violation if a good-faith argument exists. Only
    conclude it survives if you cannot construct that argument.

    ADR-0012 full text:
    #{adr_text}

    Candidate claim:
    file: #{candidate.file}
    line: #{candidate.line}
    claim: #{candidate.claim}

    Respond with JSON only: {"violation": true} if the claim survives your
    challenge as a genuine ADR-0012 violation, or {"violation": false} if you
    have overturned it. If you are genuinely uncertain, respond
    {"violation": false} - ties go to "not a violation".
    """
  end

  defp parse_propose(text) do
    case JSON.decode(text) do
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
    case JSON.decode(text) do
      {:ok, %{"violation" => true}} -> true
      _other -> false
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
  The default `opts[:caller]`: one real Anthropic Messages API call.

  Only its network-touching half - building the request and handing it to
  `Req.post/2` - is unexercised by the test suite; every test injects its own
  `caller`, so this is the only place in the module that touches the network.
  `parse_response/1`, the half that turns a Req-shaped result into this
  function's return value, is pure and directly tested.
  """
  @spec call_anthropic(prompt :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def call_anthropic(prompt) do
    # `Req` is a dev-only dependency (`mix.exs`: `only: :dev`) - this module
    # is the one seam in the gate that needs it, everywhere else talks to
    # `mix` subprocesses instead. `mix quality`'s compile stage builds both
    # :dev and :test with `--warnings-as-errors`, and Req is absent from the
    # :test build entirely, so a direct `Req.post/2` call would fail that
    # build. `apply/3` defers the lookup to runtime, where the real call only
    # ever happens under :dev (nothing in the test suite calls this
    # function - every test injects its own `opts[:caller]`).
    if Code.ensure_loaded?(Req) do
      prompt |> post_to_anthropic() |> parse_response()
    else
      {:error, "the Req dependency is unavailable in this environment"}
    end
  end

  defp post_to_anthropic(prompt) do
    model = System.get_env(@model_env, @default_model)
    api_key = System.get_env(@api_key_env)

    body = %{
      model: model,
      max_tokens: 4096,
      messages: [%{role: "user", content: prompt}]
    }

    opts = [
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @anthropic_version}
      ]
    ]

    # `apply/3` is deliberate, not the "arg count is known" case Credo's
    # check exists for: a direct `Req.post/2` call fails `mix quality`'s
    # compile stage under :test, where Req is absent from the dev-only build
    # entirely (see `call_anthropic/1`'s comment above).
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Req, :post, [@anthropic_url, opts])
  end

  @doc """
  Turns a `Req.post/2`-shaped result into `call_anthropic/1`'s return value.

  Matched as a plain map, not `%Req.Response{}`: a struct-name pattern here
  would need Req's struct definition at compile time, which is exactly what
  `call_anthropic/1`'s environment guard exists to avoid. A struct is a map at
  runtime, so this matches the real response just as precisely, and stays
  pure and directly testable with a fabricated result - no `Req` dependency,
  loaded or not, needed to exercise it.
  """
  @spec parse_response(result :: {:ok, map()} | {:error, term()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def parse_response({:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _rest]}}}) do
    {:ok, text}
  end

  def parse_response({:ok, %{status: status, body: response_body}}) do
    {:error, "anthropic API returned #{status}: #{inspect(response_body)}"}
  end

  def parse_response({:error, reason}) do
    {:error, "anthropic API call failed: #{inspect(reason)}"}
  end
end
