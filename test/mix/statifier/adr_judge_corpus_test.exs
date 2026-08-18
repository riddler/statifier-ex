defmodule Mix.Statifier.AdrJudgeCorpusTest do
  use ExUnit.Case, async: false

  alias Mix.Statifier.{AdrJudge, AdrJudgeCorpus}

  # Real `claude` CLI calls: ~11-78s per fixture (one propose call, plus one
  # refute call per proposed candidate), ~6 minutes for the whole corpus at
  # the measured baseline. Excluded by default in test_helper.exs for the same
  # reason :scion and :scxml_w3 are - and because the `:test` build's default
  # caller raises on a forgotten `opts[:caller]`, so only this module opts
  # into the real CLI, visibly, at its own call site. Run by hand:
  # `mix test --only adr_judge_corpus`.
  @moduletag :adr_judge_corpus
  @moduletag timeout: :infinity

  # The expected-verdict branch is chosen here, at generation time, rather
  # than with a `case` inside the test body: each generated test's `@entry`
  # is a literal map, so a runtime `case` over `@entry.expect` leaves the
  # other clause provably unreachable and the compiler says so on every
  # `mix test` run. One branch per test also means a failure message can
  # only be the one its fixture's row asked for.
  #
  # `tier:` and `fixture:` are the spend controls. ExUnit's include beats
  # exclude, so `mix test --only tier:subtle` and
  # `mix test --only fixture:0012_trace_after_departure.diff` reach these
  # tests despite the module's :adr_judge_corpus exclusion - a tier or a
  # single fixture, rather than the whole paid corpus. A `file:line` filter
  # cannot do this: every generated test shares this one `test` macro line.
  for entry <- AdrJudgeCorpus.manifest() do
    @entry entry

    if entry.expect == :violation do
      @tag tier: entry.tier
      @tag fixture: entry.file
      # sabotage: n/a - scores real model output against known fixtures; the
      #           implementation under test is the prompt, not a pure function
      test "#{entry.file} (#{entry.tier} violation)" do
        findings = judge(@entry)

        assert findings != [],
               "FALSE NEGATIVE: #{@entry.file} is a known #{@entry.key} violation " <>
                 "(#{@entry.note}) and produced no surviving finding"

        assert Enum.any?(findings, &(&1.check == @entry.key)),
               "WRONG ADR: #{@entry.file} survived under #{inspect(Enum.map(findings, & &1.check))}"
      end
    else
      @tag tier: entry.tier
      @tag fixture: entry.file
      # sabotage: n/a - scores real model output against known fixtures; the
      #           implementation under test is the prompt, not a pure function
      test "#{entry.file} (#{entry.tier} clean)" do
        findings = judge(@entry)

        assert findings == [],
               "FALSE POSITIVE: #{@entry.file} is known-clean for #{@entry.key} " <>
                 "and produced #{inspect(findings)}"
      end
    end
  end

  # The one place in the suite that passes the real caller, and it does so
  # visibly at its own call site - `@default_caller` and `refuse_real_call/1`
  # are untouched, so a *forgotten* caller still raises everywhere else.
  defp judge(entry) do
    AdrJudge.analyze(AdrJudgeCorpus.source_for(entry), caller: &AdrJudge.call_claude_cli/1)
  end
end
